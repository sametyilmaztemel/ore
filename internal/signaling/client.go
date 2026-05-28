// Package signaling provides the client for the Oretty signaling protocol.
package signaling

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/url"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/rs/zerolog"
)

// Message is the signaling message envelope.
type Message struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload,omitempty"`
}

// NewMessage creates a new signaling message.
func NewMessage(msgType string, payload map[string]interface{}) Message {
	return Message{Type: msgType, Payload: payload}
}

// EventHandler is a callback for signaling events.
type EventHandler func(Message)

// Client manages the WebSocket connection to the signaling server.
type Client struct {
	url        string
	deviceID   string
	deviceName string
	conn       *websocket.Conn
	mu         sync.Mutex
	handlers   map[string][]EventHandler
	log        zerolog.Logger
	done       chan struct{}
	connected  bool
	reconnect  bool
	isHost     bool
}

// NewClient creates a new signaling client.
func NewClient(signalURL, deviceID, deviceName string, log zerolog.Logger) *Client {
	return &Client{
		url:        signalURL,
		deviceID:   deviceID,
		deviceName: deviceName,
		handlers:   make(map[string][]EventHandler),
		log:        log.With().Str("component", "signaling").Logger(),
		done:       make(chan struct{}),
	}
}

// On registers an event handler for a message type.
func (c *Client) On(msgType string, handler EventHandler) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.handlers[msgType] = append(c.handlers[msgType], handler)
}

// Off removes all handlers for a message type.
func (c *Client) Off(msgType string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.handlers, msgType)
}

// Connect establishes the WebSocket connection to the signaling server.
func (c *Client) Connect(ctx context.Context) error {
	u, err := url.Parse(c.url)
	if err != nil {
		return fmt.Errorf("parse signal URL: %w", err)
	}

	u.Path = "/ws"

	dialer := websocket.DefaultDialer
	dialer.HandshakeTimeout = 10 * time.Second
	if u.Scheme == "wss" {
		dialer.TLSClientConfig = &tls.Config{
			InsecureSkipVerify: true,
		}
	}

	c.log.Info().Str("url", u.String()).Msg("Connecting to signaling server")
	conn, _, err := dialer.DialContext(ctx, u.String(), nil)
	if err != nil {
		return fmt.Errorf("dial signaling: %w", err)
	}

	c.mu.Lock()
	c.conn = conn
	c.connected = true
	c.mu.Unlock()

	c.log.Info().Msg("Connected to signaling server")

	// Set up keepalive: pong handler extends read deadline
	// Ping handler MUST send pong response for gorilla/websocket
	conn.SetPingHandler(func(appData string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return conn.WriteMessage(websocket.PongMessage, []byte(appData))
	})
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})
	conn.SetReadDeadline(time.Now().Add(60 * time.Second))

	// Server sends pings every 30s via WritePump, no need for client-side pings

	go c.readLoop()

	return nil
}

// RegisterAsHost sends a host registration message.
func (c *Client) RegisterAsHost(name, platform, arch, version string, features []string) error {
	c.isHost = true
	msg := NewMessage("register", map[string]interface{}{
		"device_id": c.deviceID,
		"is_host":   true,
		"name":      name,
		"platform":  platform,
		"arch":      arch,
		"version":   version,
		"features":  features,
	})
	return c.Send(msg)
}

// RegisterAsClient sends a client (viewer) registration message.
func (c *Client) RegisterAsClient() error {
	msg := NewMessage("register", map[string]interface{}{
		"device_id": c.deviceID,
		"is_host":   false,
	})
	return c.Send(msg)
}

// CreateRoom creates a new room (host only).
func (c *Client) CreateRoom(name string) error {
	msg := NewMessage("create_room", map[string]interface{}{
		"room_name": name,
	})
	return c.Send(msg)
}

// JoinRoom joins an existing room (viewer only).
func (c *Client) JoinRoom(roomID string) error {
	msg := NewMessage("join_room", map[string]interface{}{
		"room_id": roomID,
	})
	return c.Send(msg)
}

// SendSignal sends a signaling message to a peer in the room.
func (c *Client) SendSignal(targetID string, data map[string]interface{}) error {
	msg := NewMessage("signal", map[string]interface{}{
		"target_id": targetID,
		"data":      data,
	})
	return c.Send(msg)
}

// SendHeartbeat sends a heartbeat message.
func (c *Client) SendHeartbeat() error {
	return c.Send(NewMessage("heartbeat", nil))
}

// Send sends a message over the WebSocket connection.
func (c *Client) Send(msg Message) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}
	c.log.Debug().Str("type", msg.Type).Msg("Send: writing message")
	if err := c.conn.WriteJSON(msg); err != nil {
		c.log.Warn().Err(err).Str("type", msg.Type).Msg("Send: WriteJSON failed")
		return err
	}
	c.log.Debug().Str("type", msg.Type).Msg("Send: message sent successfully")
	return nil
}

// Close closes the signaling connection.
func (c *Client) Close() {
	c.mu.Lock()
	c.reconnect = false
	c.connected = false
	if c.conn != nil {
		c.conn.Close()
	}
	c.mu.Unlock()
	close(c.done)
}

// IsConnected returns whether the client is connected.
func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Client) SendRequestToHost(hostID string) error {
	return c.Send(NewMessage("connect", map[string]interface{}{
		"host_id":   hostID,
		"client_id": c.deviceID,
	}))
}

func (c *Client) readLoop() {
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			c.log.Warn().Err(err).Msg("Read error")
			c.mu.Lock()
			c.connected = false
			c.mu.Unlock()
			if c.reconnect {
				c.reconnectLoop()
			}
			return
		}

		var msg Message
		if err := json.Unmarshal(data, &msg); err != nil {
			c.log.Warn().Err(err).Msg("Invalid message")
			continue
		}

		c.dispatch(msg)
	}
}

func (c *Client) dispatch(msg Message) {
	c.mu.Lock()
	handlers := c.handlers[msg.Type]
	allHandlers := make([]EventHandler, len(handlers))
	copy(allHandlers, handlers)
	c.mu.Unlock()

	for _, h := range allHandlers {
		h(msg)
	}
}

func (c *Client) reconnectLoop() {
	backoff := 2 * time.Second
	maxBackoff := 60 * time.Second

	for {
		select {
		case <-c.done:
			return
		case <-time.After(backoff):
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := c.Connect(ctx)
			cancel()
			if err == nil {
				// Re-register
				if c.isHost {
					c.RegisterAsHost(c.deviceName, "", "", "", nil)
				} else {
					c.RegisterAsClient()
				}
				return
			}
			c.log.Warn().Err(err).Dur("backoff", backoff).Msg("Reconnect failed")
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

// SetReconnect enables or disables automatic reconnection.
func (c *Client) SetReconnect(enable bool) {
	c.mu.Lock()
	c.reconnect = enable
	c.mu.Unlock()
}

// keepaliveLoop sends periodic pings to keep the WebSocket connection alive.
func (c *Client) keepaliveLoop() {
	// Send first ping after 5 seconds (NAT/firewall prevention)
	firstPing := time.AfterFunc(5*time.Second, func() {
		c.mu.Lock()
		conn := c.conn
		c.mu.Unlock()
		if conn != nil {
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.log.Warn().Err(err).Msg("Ping error (initial)")
			}
		}
	})
	defer firstPing.Stop()

	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			c.mu.Lock()
			conn := c.conn
			c.mu.Unlock()
			if conn != nil {
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					c.log.Warn().Err(err).Msg("Ping error")
					return
				}
			}
		case <-c.done:
			return
		}
	}
}
