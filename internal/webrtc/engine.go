// Package webrtc provides the WebRTC engine for Oretty with video track support.
package webrtc

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/pion/interceptor"
	pion "github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/rs/zerolog"

	"github.com/sametyilmaztemel/ore/internal/signaling"
)

// Data channel labels
const (
	DCAuth     = "auth"
	DCTerminal = "terminal"
	DCScreen   = "screen"
	DCControl  = "control"
	DCClipboard = "clipboard"
	DCFile     = "file"
)

// EngineConfig holds configuration for the WebRTC engine.
type EngineConfig struct {
	SignalClient      *signaling.Client
	RoomID            string
	TargetPeerID      string
	ICEServers        []pion.ICEServer
	OnDataChannel     func(label string, dc *pion.DataChannel)
	OnICEState        func(state pion.ICEConnectionState)
	Log               zerolog.Logger
	IsOfferer         bool
	OnRemoteSignal    func(data map[string]interface{})
}

// Engine manages a WebRTC peer connection with video track + data channels.
type Engine struct {
	pc            *pion.PeerConnection
	config        EngineConfig
	mu            sync.Mutex
	dataChannels  map[string]*pion.DataChannel
	videoTrack    *pion.TrackLocalStaticSample
	closed        bool
	reconnectStop chan struct{}
	restarting    bool
	restartMu     sync.Mutex
	log           zerolog.Logger
}

// NewEngine creates a new WebRTC engine.
func NewEngine(cfg EngineConfig) (*Engine, error) {
	if cfg.Log.GetLevel() == zerolog.NoLevel {
		cfg.Log = zerolog.Nop()
	}
	cfg.Log = cfg.Log.With().Str("component", "webrtc").Logger()

	if cfg.ICEServers == nil {
		cfg.ICEServers = []pion.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		}
	}

	m := &pion.MediaEngine{}

	// Register VP8 only (tested working)
	videoRTCPFeedback := []pion.RTCPFeedback{{"goog-remb", ""}, {"ccm", "fir"}, {"nack", ""}, {"nack", "pli"}}
	_ = m.RegisterCodec(pion.RTPCodecParameters{
		RTPCodecCapability: pion.RTPCodecCapability{
			MimeType:     pion.MimeTypeVP8,
			ClockRate:    90000,
			Channels:     0,
			SDPFmtpLine:  "",
			RTCPFeedback: videoRTCPFeedback,
		},
		PayloadType: 96,
	}, pion.RTPCodecTypeVideo)

	// Register Opus for audio
	_ = m.RegisterCodec(pion.RTPCodecParameters{
		RTPCodecCapability: pion.RTPCodecCapability{MimeType: pion.MimeTypeOpus, ClockRate: 48000, Channels: 2,
			SDPFmtpLine: "minptime=10;useinbandfec=1"},
		PayloadType: 111,
	}, pion.RTPCodecTypeAudio)

	i := &interceptor.Registry{}
	if err := pion.RegisterDefaultInterceptors(m, i); err != nil {
		return nil, fmt.Errorf("register interceptors: %w", err)
	}

	api := pion.NewAPI(
		pion.WithMediaEngine(m),
		pion.WithInterceptorRegistry(i),
	)

	config := pion.Configuration{
		ICEServers:        cfg.ICEServers,
		ICETransportPolicy: pion.ICETransportPolicyAll,
	}

	pc, err := api.NewPeerConnection(config)
	if err != nil {
		return nil, fmt.Errorf("create peer connection: %w", err)
	}

	e := &Engine{
		pc:            pc,
		config:        cfg,
		dataChannels:  make(map[string]*pion.DataChannel),
		reconnectStop: make(chan struct{}),
		log:           cfg.Log,
	}

	pc.OnICEConnectionStateChange(e.onICEStateChange)
	pc.OnDataChannel(e.onDataChannel)
	pc.OnICECandidate(e.onICECandidate)
	pc.OnTrack(e.onTrack)

	return e, nil
}

// CreateOffer initiates a WebRTC connection by creating an offer.
func (e *Engine) CreateOffer() error {
	offer, err := e.pc.CreateOffer(nil)
	if err != nil {
		return fmt.Errorf("create offer: %w", err)
	}
	if err := e.pc.SetLocalDescription(offer); err != nil {
		return fmt.Errorf("set local description: %w", err)
	}

	// Log the complete offer SDP for debugging
	e.log.Info().Str("sdp", offer.SDP).Msg("SDP offer created")

	// Send via signaling's signal relay
	signalData := map[string]interface{}{
		"type": "offer",
		"sdp":  offer.SDP,
	}

	// Send to the peer targeted to our room
	msg := signaling.NewMessage("signal", map[string]interface{}{
		"target_id": e.config.TargetPeerID,
		"data":      signalData,
	})
	return e.config.SignalClient.Send(msg)
}

// CreateDataChannel creates a new data channel.
func (e *Engine) CreateDataChannel(label string) (*pion.DataChannel, error) {
	dc, err := e.pc.CreateDataChannel(label, &pion.DataChannelInit{
		Ordered: boolPtr(true),
	})
	if err != nil {
		return nil, fmt.Errorf("create data channel %s: %w", label, err)
	}

	e.mu.Lock()
	e.dataChannels[label] = dc
	e.mu.Unlock()

	dc.OnOpen(func() {
		e.log.Debug().Str("label", label).Msg("Data channel opened")
		if e.config.OnDataChannel != nil {
			e.config.OnDataChannel(label, dc)
		}
	})
	dc.OnClose(func() {
		e.log.Debug().Str("label", label).Msg("Data channel closed")
	})
	return dc, nil
}

// AddVideoTrack adds a VP8 video track for screen sharing.
func (e *Engine) AddVideoTrack() (*pion.TrackLocalStaticSample, error) {
	track, err := pion.NewTrackLocalStaticSample(
		pion.RTPCodecCapability{
			MimeType:  pion.MimeTypeVP8,
			ClockRate: 90000,
		},
		"screen",
		uuid.New().String(),
	)
	if err != nil {
		return nil, fmt.Errorf("create video track: %w", err)
	}

	_, err = e.pc.AddTrack(track)
	if err != nil {
		return nil, fmt.Errorf("add video track: %w", err)
	}

	e.mu.Lock()
	e.videoTrack = track
	e.mu.Unlock()

	e.log.Info().Str("codec", string(pion.MimeTypeVP8)).Msg("Video track added (VP8)")
	return track, nil
}

// WriteVideoSample writes a VP8 sample to the video track.
func (e *Engine) WriteVideoSample(data []byte) error {
	e.mu.Lock()
	track := e.videoTrack
	e.mu.Unlock()
	if track == nil {
		return nil // Video not started yet
	}
	err := track.WriteSample(media.Sample{Data: data, Duration: 16 * time.Millisecond})
	if err != nil {
		e.log.Warn().Err(err).Int("len", len(data)).Msg("WriteVideoSample error")
	}
	return err
}

// HandleSignalingMessage processes an incoming signaling message.
func (e *Engine) HandleSignalingMessage(msg interface{}) error {
	// Marshal/unmarshal to handle the generic interface
	b, _ := json.Marshal(msg)
	var parsed struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
		SDP     string          `json:"sdp"`
		Room    string          `json:"room"`
	}
	json.Unmarshal(b, &parsed)

	switch parsed.Type {
	case "offer":
		var offer struct{ SDP string }
		if parsed.SDP != "" {
			offer.SDP = parsed.SDP
		} else if len(parsed.Payload) > 0 {
			json.Unmarshal(parsed.Payload, &offer)
		}
		return e.handleOffer(offer.SDP)

	case "answer":
		var answer struct{ SDP string }
		if parsed.SDP != "" {
			answer.SDP = parsed.SDP
		} else if len(parsed.Payload) > 0 {
			json.Unmarshal(parsed.Payload, &answer)
		}
		return e.handleAnswer(answer.SDP)

	case "ice_candidate":
		var candidate struct {
			Candidate     string `json:"candidate"`
			SDPMid        string `json:"sdpMid"`
			SDPMLineIndex *int   `json:"sdpMLineIndex"`
		}
		if len(parsed.Payload) > 0 {
			json.Unmarshal(parsed.Payload, &candidate)
		} else {
			json.Unmarshal(b, &candidate)
		}
		return e.handleICE(candidate.Candidate, candidate.SDPMid, candidate.SDPMLineIndex)
	}
	return nil
}

// Close closes the peer connection.
func (e *Engine) Close() {
	e.mu.Lock()
	e.closed = true
	e.mu.Unlock()

	select {
	case e.reconnectStop <- struct{}{}:
	default:
	}

	if e.pc != nil {
		e.pc.Close()
	}
}

// IsClosed returns whether the engine is closed.
func (e *Engine) IsClosed() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.closed
}

// ─── Internal Handlers ──────────────────────────

func (e *Engine) onICEStateChange(state pion.ICEConnectionState) {
	e.log.Debug().Str("state", state.String()).Msg("ICE state changed")
	if e.config.OnICEState != nil {
		e.config.OnICEState(state)
	}
	switch state {
	case pion.ICEConnectionStateConnected, pion.ICEConnectionStateCompleted:
		e.log.Info().Msg("WebRTC connection established")
	}
}

func (e *Engine) onDataChannel(dc *pion.DataChannel) {
	e.mu.Lock()
	e.dataChannels[dc.Label()] = dc
	e.mu.Unlock()

	dc.OnOpen(func() {
		e.log.Debug().Str("label", dc.Label()).Msg("Remote data channel opened")
		if e.config.OnDataChannel != nil {
			e.config.OnDataChannel(dc.Label(), dc)
		}
	})
}

func (e *Engine) onICECandidate(candidate *pion.ICECandidate) {
	e.log.Debug().Bool("is_nil", candidate == nil).Msg("onICECandidate called")
	if candidate == nil || e.closed {
		e.log.Debug().Msg("onICECandidate: nil or closed, skipping")
		return
	}
	candJSON := candidate.ToJSON()
	e.log.Debug().Str("candidate", candJSON.Candidate).Msg("onICECandidate: sending")
	signalData := map[string]interface{}{
		"type":           "ice_candidate",
		"candidate":      candJSON.Candidate,
		"sdpMid":         *candJSON.SDPMid,
		"sdpMLineIndex":  *candJSON.SDPMLineIndex,
	}
	msg := signaling.NewMessage("signal", map[string]interface{}{
		"target_id": e.config.TargetPeerID,
		"data":      signalData,
	})
	if err := e.config.SignalClient.Send(msg); err != nil {
		e.log.Warn().Err(err).Msg("onICECandidate: failed to send candidate")
	}
}

func (e *Engine) onTrack(track *pion.TrackRemote, receiver *pion.RTPReceiver) {
	e.log.Info().Str("kind", track.Kind().String()).Msg("Incoming track")
}

// ─── SDP Handling ───────────────────────────────

func (e *Engine) handleOffer(sdp string) error {
	if sdp == "" {
		return fmt.Errorf("empty SDP offer")
	}
	if err := e.pc.SetRemoteDescription(pion.SessionDescription{
		Type: pion.SDPTypeOffer,
		SDP:  sdp,
	}); err != nil {
		return fmt.Errorf("set remote description: %w", err)
	}

	answer, err := e.pc.CreateAnswer(nil)
	if err != nil {
		return fmt.Errorf("create answer: %w", err)
	}
	if err := e.pc.SetLocalDescription(answer); err != nil {
		return fmt.Errorf("set local description: %w", err)
	}

	signalData := map[string]interface{}{
		"type": "answer",
		"sdp":  answer.SDP,
	}
	msg := signaling.NewMessage("signal", map[string]interface{}{
		"target_id": e.config.TargetPeerID,
		"data":      signalData,
	})
	return e.config.SignalClient.Send(msg)
}

func (e *Engine) handleAnswer(sdp string) error {
	if sdp == "" {
		return fmt.Errorf("empty SDP answer")
	}
	return e.pc.SetRemoteDescription(pion.SessionDescription{
		Type: pion.SDPTypeAnswer,
		SDP:  sdp,
	})
}

func (e *Engine) handleICE(candidate, sdpMid string, sdpMLineIndex *int) error {
	init := pion.ICECandidateInit{
		Candidate: candidate,
	}
	if sdpMid != "" {
		init.SDPMid = &sdpMid
	}
	if sdpMLineIndex != nil {
		idx := uint16(*sdpMLineIndex)
		init.SDPMLineIndex = &idx
	}
	return e.pc.AddICECandidate(init)
}

func boolPtr(b bool) *bool {
	return &b
}
