package signaling

import (
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Client represents a WebSocket connection (host or viewer).
type Client struct {
	conn     *websocket.Conn
	hub      *Hub
	db       *Database
	ID       string
	DeviceID string
	RoomID   string
	IsHost   bool
	Send     chan []byte
	mu       sync.Mutex
}

// NewClient creates a new client.
func NewClient(conn *websocket.Conn, hub *Hub, db *Database) *Client {
	return &Client{
		conn:   conn,
		hub:    hub,
		db:     db,
		Send:   make(chan []byte, 256),
	}
}

// ReadPump reads messages from the WebSocket connection.
func (c *Client) ReadPump() {
	defer func() {
		c.hub.Unregister <- c
		c.conn.Close()
	}()

	c.conn.SetReadLimit(65536)
	c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})
	c.conn.SetPingHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				logf("WebSocket error: %v", err)
			}
			break
		}

		c.handleMessage(message)
	}
}

// WritePump writes messages to the WebSocket connection.
func (c *Client) WritePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.Send:
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *Client) handleMessage(message []byte) {
	var msg Message
	if err := msg.Unmarshal(message); err != nil {
		logf("Invalid message: %v", err)
		return
	}

	switch msg.Type {
	case MsgTypeRegister:
		c.handleRegister(msg)
	case MsgTypeHeartbeat:
		c.handleHeartbeat()
	case MsgTypeCreateRoom:
		c.handleCreateRoom(msg)
	case MsgTypeJoinRoom:
		c.handleJoinRoom(msg)
	case MsgTypeSignal:
		c.handleSignal(msg)
	case MsgTypeLeaveRoom:
		c.handleLeaveRoom()
	default:
		logf("Unknown message type: %s", msg.Type)
	}
}

func (c *Client) handleRegister(msg Message) {
	deviceID, _ := msg.Payload["device_id"].(string)
	isHost, _ := msg.Payload["is_host"].(bool)

	if deviceID == "" {
		c.sendError("device_id is required")
		return
	}

	// Re-key the client in the hub if the ID changed (initial ID was empty)
	c.hub.UpdateClientID(c.ID, deviceID)

	c.ID = deviceID
	c.DeviceID = deviceID
	c.IsHost = isHost

	if isHost {
		c.hub.RegisterHost(c)
	}

	logf("Client registered: id=%s isHost=%v", deviceID, isHost)
	c.sendMessage(Message{
		Type: MsgTypeRegistered,
		Payload: map[string]interface{}{
			"client_id": deviceID,
			"is_host":   isHost,
		},
	})
}

func (c *Client) handleHeartbeat() {
	if c.IsHost {
		c.hub.UpdateHostHeartbeat(c)
	}
	c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
}

func (c *Client) handleCreateRoom(msg Message) {
	if !c.IsHost {
		c.sendError("Only hosts can create rooms")
		return
	}

	roomName, _ := msg.Payload["room_name"].(string)
	if roomName == "" {
		roomName = c.DeviceID + "-room"
	}

	room := c.hub.CreateRoom(c, roomName)
	logf("Room created: %s by host %s", room.ID, c.DeviceID)

	c.sendMessage(Message{
		Type: MsgTypeRoomCreated,
		Payload: map[string]interface{}{
			"room_id":   room.ID,
			"room_name": room.Name,
		},
	})
}

func (c *Client) handleJoinRoom(msg Message) {
	roomID, _ := msg.Payload["room_id"].(string)
	if roomID == "" {
		c.sendError("room_id is required")
		return
	}

	room, err := c.hub.JoinRoom(c, roomID)
	if err != nil {
		c.sendError(err.Error())
		return
	}

	logf("Client %s joined room %s", c.DeviceID, roomID)

	c.sendMessage(Message{
		Type: MsgTypeJoinedRoom,
		Payload: map[string]interface{}{
			"room_id":   room.ID,
			"room_name": room.Name,
		},
	})
}

func (c *Client) handleSignal(msg Message) {
	targetID, _ := msg.Payload["target_id"].(string)
	if targetID == "" {
		c.sendError("target_id is required")
		return
	}

	if c.RoomID == "" {
		logf("handleSignal: client=%s not in a room", c.DeviceID)
		c.sendError("Not in a room")
		return
	}

	logf("handleSignal: client=%s room=%s target=%s", c.DeviceID, c.RoomID, targetID)
	c.hub.RelaySignal(c.RoomID, c.DeviceID, targetID, msg)
}

func (c *Client) handleLeaveRoom() {
	if c.RoomID == "" {
		return
	}

	c.hub.LeaveRoom(c)
	logf("Client %s left room %s", c.DeviceID, c.RoomID)
}

func (c *Client) sendMessage(msg Message) {
	defer func() {
		if r := recover(); r != nil {
			logf("Recovered in sendMessage: %v", r)
		}
	}()
	data, err := msg.Marshal()
	if err != nil {
		logf("Error marshaling message: %v", err)
		return
	}
	select {
	case c.Send <- data:
	default:
		logf("Client %s send buffer full, dropping message", c.DeviceID)
	}
}

func (c *Client) sendError(errMsg string) {
	c.sendMessage(Message{
		Type: MsgTypeError,
		Payload: map[string]interface{}{
			"message": errMsg,
		},
	})
}
