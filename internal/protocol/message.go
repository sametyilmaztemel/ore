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