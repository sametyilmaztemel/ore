package signaling

import (
	"encoding/json"
	"sync"
	"time"
)

// Message types for WebSocket communication.
const (
	MsgTypeRegister    = "register"
	MsgTypeRegistered  = "registered"
	MsgTypeHeartbeat   = "heartbeat"
	MsgTypeCreateRoom  = "create_room"
	MsgTypeRoomCreated = "room_created"
	MsgTypeJoinRoom    = "join_room"
	MsgTypeJoinedRoom  = "joined_room"
	MsgTypeSignal      = "signal"
	MsgTypeLeaveRoom   = "leave_room"
	MsgTypePeerJoined  = "peer_joined"
	MsgTypePeerLeft    = "peer_left"
	MsgTypeError       = "error"
)

// Message represents a JSON message exchanged over WebSocket.
type Message struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload"`
}

// Marshal converts a Message to JSON bytes.
func (m *Message) Marshal() ([]byte, error) {
	return json.Marshal(m)
}

// Unmarshal parses JSON bytes into a Message.
func (m *Message) Unmarshal(data []byte) error {
	return json.Unmarshal(data, m)
}

// Room represents a signaling room with a host and connected peers.
type Room struct {
	ID        string
	Name      string
	Host      *Client
	Peers     map[string]*Client
	CreatedAt time.Time
	LastUsed  time.Time
	mu        sync.RWMutex
}

// NewRoom creates a new room.
func NewRoom(id, name string, host *Client) *Room {
	now := time.Now()
	return &Room{
		ID:        id,
		Name:      name,
		Host:      host,
		Peers:     make(map[string]*Client),
		CreatedAt: now,
		LastUsed:  now,
	}
}

// IsExpired checks if the room has been idle for longer than the timeout.
func (r *Room) IsExpired(timeout time.Duration) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return time.Since(r.LastUsed) > timeout
}

// Touch updates the last used timestamp.
func (r *Room) Touch() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.LastUsed = time.Now()
}

// AddPeer adds a client to the room.
func (r *Room) AddPeer(client *Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.Peers[client.DeviceID] = client
	client.RoomID = r.ID
	r.LastUsed = time.Now()
}

// RemovePeer removes a client from the room.
func (r *Room) RemovePeer(deviceID string) *Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	client, ok := r.Peers[deviceID]
	if ok {
		delete(r.Peers, deviceID)
		client.RoomID = ""
	}
	r.LastUsed = time.Now()
	return client
}

// PeerCount returns the number of peers in the room.
func (r *Room) PeerCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.Peers)
}
