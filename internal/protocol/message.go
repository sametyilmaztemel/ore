// Package protocol defines the message types and payloads for Oretty signaling
// and data channel communication.
package protocol

import "encoding/json"

// Message types for signaling server
const (
	MsgRegister     = "register"
	MsgHostList     = "host_list"
	MsgConnect      = "connect"
	MsgDisconnect   = "disconnect"
	MsgRoomReady    = "room_ready"
	MsgOffer        = "offer"
	MsgAnswer       = "answer"
	MsgICECandidate = "ice_candidate"
	MsgPeerLeft     = "peer_left"
	MsgHeartbeat    = "heartbeat"
	MsgError        = "error"
	MsgAuth         = "auth"
	MsgAuthOK       = "auth_ok"
	MsgAuthFail     = "auth_fail"
	MsgPairRequest  = "pair_request"
	MsgPairResponse = "pair_response"
	MsgScreenStart  = "screen_start"
	MsgScreenStop   = "screen_stop"
	MsgClipboard    = "clipboard"
	MsgResize       = "resize"
	MsgMouseMove    = "mouse_move"
	MsgMouseClick   = "mouse_click"
	MsgMouseScroll  = "mouse_scroll"
	MsgKeyEvent     = "key_event"
	MsgUnlock       = "unlock"
)

// Message is the envelope for all signaling and data channel messages.
type Message struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Room    string          `json:"room,omitempty"`
	From    string          `json:"from,omitempty"`
	To      string          `json:"to,omitempty"`
}

// NewMessage creates a new Message with the given type and payload.
func NewMessage(msgType string, payload interface{}) Message {
	var raw json.RawMessage
	if payload != nil {
		raw, _ = json.Marshal(payload)
	}
	return Message{
		Type:    msgType,
		Payload: raw,
	}
}

// RegisterPayload is sent by a host when connecting to the signaling server.
type RegisterPayload struct {
	Name     string   `json:"name"`
	Platform string   `json:"platform"`
	Arch     string   `json:"arch"`
	Version  string   `json:"version"`
	Features []string `json:"features"`
	DeviceID string   `json:"device_id"`
}

// HostInfo represents a registered host machine.
type HostInfo struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Platform string   `json:"platform"`
	Arch     string   `json:"arch"`
	Version  string   `json:"version"`
	Features []string `json:"features"`
	Online   bool     `json:"online"`
}

// AuthPayload is sent over the auth data channel for password verification.
type AuthPayload struct {
	Password string `json:"password"`
}

// ConnectPayload is sent by a client to request connection to a host.
type ConnectPayload struct {
	HostID   string `json:"host_id"`
	ClientID string `json:"client_id"`
	Room     string `json:"room,omitempty"`
}

// RoomReadyPayload is the signaling response when a room is ready.
type RoomReadyPayload struct {
	Room string `json:"room"`
	Host string `json:"host"`
}

// PairRequestPayload is sent to initiate device pairing.
type PairRequestPayload struct {
	Code     string `json:"code"`
	DeviceID string `json:"device_id"`
	Name     string `json:"name"`
}

// PairResponsePayload is the response to a pairing request.
type PairResponsePayload struct {
	Success bool   `json:"success"`
	Token   string `json:"token,omitempty"`
	Error   string `json:"error,omitempty"`
}

// ScreenFramePayload carries a JPEG-encoded screen frame over the data channel.
// DEPRECATED: Use WebRTC Video Track instead. Kept for fallback.
type ScreenFramePayload struct {
	Width  int    `json:"width"`
	Height int    `json:"height"`
	Data   string `json:"data"` // base64-encoded JPEG
}

// MouseEventPayload represents a mouse event from the client.
type MouseEventPayload struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Button int     `json:"button,omitempty"`
	Down   bool    `json:"down,omitempty"`
	DeltaX float64 `json:"delta_x,omitempty"`
	DeltaY float64 `json:"delta_y,omitempty"`
}

// KeyEventPayload represents a keyboard event from the client.
type KeyEventPayload struct {
	Key      string   `json:"key"`
	Code     string   `json:"code"`
	Modifiers []string `json:"modifiers,omitempty"`
	Down     bool     `json:"down"`
}

// ResizePayload is sent when the terminal is resized.
type ResizePayload struct {
	Rows int `json:"rows"`
	Cols int `json:"cols"`
}

// ClipboardPayload carries clipboard data between peers.
type ClipboardPayload struct {
	Text string `json:"text"`
}

// UnlockPayload is sent to attempt unlocking the Mac.
type UnlockPayload struct {
	Password string `json:"password"`
}
