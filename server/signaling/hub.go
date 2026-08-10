package signaling

import (
	"errors"
	"fmt"
	"log"
	"sync"
	"time"
)

func logf(format string, v ...interface{}) {
	log.Printf("[signaling] "+format, v...)
}

// Hub manages all WebSocket connections, rooms, and hosts.
type Hub struct {
	// Registered clients (by device ID)
	Clients map[string]*Client

	// Active hosts (by device ID)
	Hosts map[string]*Client

	// Rooms by ID
	Rooms map[string]*Room

	// Register/unregister channels
	Register   chan *Client
	Unregister chan *Client

	// Database instance
	db *Database

	// Pairing code management
	pairingCodes map[string]PairingCode

	mu    sync.RWMutex
	stop  chan struct{}
	done  bool
}

// NewHub creates a new Hub.
func NewHub(db *Database) *Hub {
	return &Hub{
		Clients:       make(map[string]*Client),
		Hosts:         make(map[string]*Client),
		Rooms:         make(map[string]*Room),
		Register:      make(chan *Client),
		Unregister:    make(chan *Client),
		db:            db,
		pairingCodes:  make(map[string]PairingCode),
		stop:          make(chan struct{}),
	}
}

// Run starts the hub's main event loop.
func (h *Hub) Run() {
	roomCleanupTicker := time.NewTicker(2 * time.Minute)
	hostTimeoutTicker := time.NewTicker(15 * time.Second)
	defer roomCleanupTicker.Stop()
	defer hostTimeoutTicker.Stop()

	for {
		select {
		case client := <-h.Register:
			h.mu.Lock()
			if existing, ok := h.Clients[client.ID]; ok {
				// Clean up old client — close its send channel and remove from hosts
				if existing.IsHost {
					delete(h.Hosts, existing.DeviceID)
					logf("Host %s replaced by new connection", existing.DeviceID)
				}
				close(existing.Send)
				delete(h.Clients, client.ID)
			}
			h.Clients[client.ID] = client
			h.mu.Unlock()

		case client := <-h.Unregister:
			h.mu.Lock()
			// Only clean up if this client is still the active one for its ID
			// (a newer connection may have already replaced it via Register)
			if existing, ok := h.Clients[client.ID]; ok && existing == client {
				// Remove from room if in one
				if client.RoomID != "" {
					if room, ok := h.Rooms[client.RoomID]; ok {
						room.RemovePeer(client.DeviceID)
						// Notify host
						if room.Host != nil && room.Host != client {
							room.Host.sendMessage(Message{
								Type: MsgTypePeerLeft,
								Payload: map[string]interface{}{
									"peer_id": client.DeviceID,
								},
							})
						}
						// Notify remaining peers
						for _, peer := range room.Peers {
							if peer != client {
								peer.sendMessage(Message{
									Type: MsgTypePeerLeft,
									Payload: map[string]interface{}{
										"peer_id": client.DeviceID,
									},
								})
							}
						}
					}
				}

				// Remove from hosts if applicable
				if client.IsHost {
					delete(h.Hosts, client.DeviceID)
				}

				delete(h.Clients, client.ID)
				close(client.Send)
			}
			h.mu.Unlock()

		case <-hostTimeoutTicker.C:
			h.checkHostTimeouts()

		case <-roomCleanupTicker.C:
			h.cleanupExpiredRooms()

		case <-h.stop:
			return
		}
	}
}

// Stop stops the hub.
func (h *Hub) Stop() {
	if h.done {
		return
	}
	h.done = true
	close(h.stop)
}

// UpdateClientID re-keys a client in the Clients map when its ID changes.
func (h *Hub) UpdateClientID(oldID, newID string) {
	if oldID == newID {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if client, ok := h.Clients[oldID]; ok {
		delete(h.Clients, oldID)
		h.Clients[newID] = client
	}
}

// RegisterHost registers a client as a host.
func (h *Hub) RegisterHost(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.Hosts[client.DeviceID] = client
	logf("Host registered: %s", client.DeviceID)
}

// UpdateHostHeartbeat updates the last heartbeat time of a host.
func (h *Hub) UpdateHostHeartbeat(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	// Touch the host's entry to keep it alive
	h.Hosts[client.DeviceID] = client
}

// ListActiveHosts returns a list of active hosts.
func (h *Hub) ListActiveHosts() []map[string]interface{} {
	h.mu.RLock()
	defer h.mu.RUnlock()

	var hosts []map[string]interface{}
	for id := range h.Hosts {
		hosts = append(hosts, map[string]interface{}{
			"device_id": id,
			"status":    "online",
		})
	}
	return hosts
}

// ActiveHostCount returns the number of active hosts.
func (h *Hub) ActiveHostCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.Hosts)
}

// ActiveRoomCount returns the number of active rooms.
func (h *Hub) ActiveRoomCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.Rooms)
}

func (h *Hub) checkHostTimeouts() {
	h.mu.Lock()
	defer h.mu.Unlock()

	for id, client := range h.Hosts {
		_ = client // We use the host's presence as the heartbeat marker
		// If host disconnected, it will be removed via Unregister channel
		// This is a safety check for stale entries
		if _, exists := h.Clients[id]; !exists {
			delete(h.Hosts, id)
			logf("Host %s removed (disconnected)", id)
		}
	}
}

func (h *Hub) cleanupExpiredRooms() {
	h.mu.Lock()
	defer h.mu.Unlock()

	timeout := 10 * time.Minute
	for id, room := range h.Rooms {
		if room.IsExpired(timeout) {
			// Notify remaining clients
			if room.Host != nil {
				room.Host.sendMessage(Message{
					Type: MsgTypeError,
					Payload: map[string]interface{}{
						"message": "Room expired due to inactivity",
					},
				})
				room.Host.RoomID = ""
			}
			for _, peer := range room.Peers {
				peer.sendMessage(Message{
					Type: MsgTypeError,
					Payload: map[string]interface{}{
						"message": "Room expired due to inactivity",
					},
				})
				peer.RoomID = ""
			}
			delete(h.Rooms, id)
			logf("Room %s cleaned up (inactive)", id)
		}
	}
}

// CreateRoom creates a new room for a host.
func (h *Hub) CreateRoom(host *Client, name string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()

	roomID := fmt.Sprintf("%s-%d", host.DeviceID, time.Now().UnixNano()%10000)
	room := NewRoom(roomID, name, host)
	host.RoomID = roomID
	h.Rooms[roomID] = room
	return room
}

// JoinRoom adds a client to an existing room.
func (h *Hub) JoinRoom(client *Client, roomID string) (*Room, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	room, ok := h.Rooms[roomID]
	if !ok {
		return nil, errors.New("room not found")
	}

	room.AddPeer(client)
	client.RoomID = roomID

	// Notify host about new peer
	room.Host.sendMessage(Message{
		Type: MsgTypePeerJoined,
		Payload: map[string]interface{}{
			"peer_id": client.DeviceID,
		},
	})

	return room, nil
}

// LeaveRoom removes a client from its current room.
func (h *Hub) LeaveRoom(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if client.RoomID == "" {
		return
	}

	room, ok := h.Rooms[client.RoomID]
	if !ok {
		client.RoomID = ""
		return
	}

	room.RemovePeer(client.DeviceID)

	// If host left, remove the entire room
	if client == room.Host {
		for _, peer := range room.Peers {
			peer.sendMessage(Message{
				Type: MsgTypeError,
				Payload: map[string]interface{}{
					"message": "Host disconnected",
				},
			})
			peer.RoomID = ""
		}
		delete(h.Rooms, room.ID)
		logf("Room %s removed (host left)", room.ID)
	} else {
		// Notify host
		room.Host.sendMessage(Message{
			Type: MsgTypePeerLeft,
			Payload: map[string]interface{}{
				"peer_id": client.DeviceID,
			},
		})
	}

	client.RoomID = ""
}

// RelaySignal relays a signaling message between peers in a room.
func (h *Hub) RelaySignal(roomID, senderID, targetID string, msg Message) {
	h.mu.RLock()
	room, ok := h.Rooms[roomID]
	h.mu.RUnlock()

	if !ok {
		logf("RelaySignal: room %s not found", roomID)
		return
	}

	room.Touch()

	// Try to send to target peer
	room.mu.RLock()
	target, ok := room.Peers[targetID]
	if !ok {
		// Maybe it's the host
		if room.Host != nil && room.Host.DeviceID == targetID {
			target = room.Host
			ok = true
		}
	}
	room.mu.RUnlock()

	if !ok {
		logf("RelaySignal: target %s not found in room %s (host=%s, peers=%d)", targetID, roomID, room.Host.DeviceID, len(room.Peers))
		return
	}

	logf("RelaySignal: room=%s sender=%s target=%s", roomID, senderID, targetID)

	target.sendMessage(Message{
		Type: MsgTypeSignal,
		Payload: map[string]interface{}{
			"sender_id": senderID,
			"data":      msg.Payload["data"],
		},
	})
}

// NotifyHostRoomCreated sends a room_created message to the host client.
func (h *Hub) NotifyHostRoomCreated(hostID string, roomID string, roomName string) {
	h.mu.RLock()
	client, ok := h.Hosts[hostID]
	h.mu.RUnlock()
	if ok && client != nil {
		client.sendMessage(Message{
			Type: MsgTypeRoomCreated,
			Payload: map[string]interface{}{
				"room_id":   roomID,
				"room_name": roomName,
			},
		})
	}
}

// GetHostClient returns the client for a given host device ID.
func (h *Hub) GetHostClient(hostID string) *Client {
	h.mu.RLock()
	defer h.mu.RUnlock()
	client, ok := h.Hosts[hostID]
	if !ok {
		return nil
	}
	return client
}

// VerifyPairingCode checks a pairing code and returns device/host IDs.
func (h *Hub) VerifyPairingCode(code string) (string, string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	pairing, ok := h.pairingCodes[code]
	if !ok {
		return "", "", errors.New("invalid pairing code")
	}

	if time.Since(pairing.CreatedAt) > 5*time.Minute {
		delete(h.pairingCodes, code)
		return "", "", errors.New("pairing code expired")
	}

	deviceID := pairing.DeviceID
	hostID := pairing.HostID
	delete(h.pairingCodes, code)

	// Log the pairing
	h.db.LogConnection(deviceID, hostID, "paired")

	return deviceID, hostID, nil
}

// GeneratePairingCode creates a new pairing code for a host-requested pairing.
func (h *Hub) GeneratePairingCode(deviceID, hostID string) string {
	h.mu.Lock()
	defer h.mu.Unlock()

	code := GenerateCode(8)
	h.pairingCodes[code] = PairingCode{
		Code:      code,
		DeviceID:  deviceID,
		HostID:    hostID,
		CreatedAt: time.Now(),
	}
	return code
}
