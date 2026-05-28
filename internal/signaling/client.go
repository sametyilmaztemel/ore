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