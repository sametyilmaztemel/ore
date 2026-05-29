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