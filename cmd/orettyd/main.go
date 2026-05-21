// Command orettyd is the Oretty host daemon for macOS with integrated menu bar.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/getlantern/systray"
	"github.com/google/uuid"
	pion "github.com/pion/webrtc/v4"
	"github.com/rs/zerolog"

	"github.com/sametyilmaztemel/ore/internal/api"
	"github.com/sametyilmaztemel/ore/internal/clipboard"
	"github.com/sametyilmaztemel/ore/internal/menubar"
	"github.com/sametyilmaztemel/ore/internal/pty"
	"github.com/sametyilmaztemel/ore/internal/screen"
	"github.com/sametyilmaztemel/ore/internal/signaling"
	"github.com/sametyilmaztemel/ore/internal/webrtc"
)

var Version = "dev"
var Commit = "none"

func main() {
	logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339}).
		With().Timestamp().Logger()

	signalURL := flag.String("signal", "wss://161.118.185.63:443", "Signaling server URL")
	hostName := flag.String("name", "", "Host name")
	noMenuBar := flag.Bool("no-menubar", false, "Run without menu bar (headless mode)")
	showVersion := flag.Bool("version", false, "Show version")
	flag.Parse()

	if *showVersion {
		fmt.Printf("orettyd %s (commit %s)\n", Version, Commit)
		return
	}

	if *hostName == "" {
		*hostName, _ = os.Hostname()
	}

	deviceID := getDeviceID()

	logger.Info().
		Str("version", Version).
		Str("signal", *signalURL).
		Str("name", *hostName).
		Str("device_id", deviceID).
		Bool("menubar", !*noMenuBar).
		Msg("Starting Oretty daemon")

	if *noMenuBar {
		// Headless mode: original daemon behavior
		runDaemon(logger, *signalURL, *hostName, deviceID, nil)
		return
	}

	// Menu bar mode: systray runs on main goroutine, daemon in background
	menubar.SetLogger(logger)
	menubar.SetOnQuit(func() {
		systray.Quit()
	})

	var daemonWg sync.WaitGroup
	daemonWg.Add(1)
	go func() {
		defer daemonWg.Done()
		runDaemon(logger, *signalURL, *hostName, deviceID, menubar.UpdateStatus)
	}()

	systray.Run(menubar.OnReady, menubar.OnExit)
	daemonWg.Wait()
}

// runDaemon starts the oretty daemon (signaling client + WebRTC).
func runDaemon(logger zerolog.Logger, signalURL, hostName, deviceID string, statusFn func(connected bool, code string)) {
	// Start local API server (for potential use)
	var localAPI = api.NewLocalAPIServer(hostName, deviceID)
	localAPI.RefreshCode = func() {
		generatePairingCode(logger, signalURL, deviceID, localAPI, func(code string) {
			logger.Info().Str("code", code).Msg("Pairing code refreshed via API")
			if statusFn != nil {
				statusFn(true, code)
			}
		})
	}
	localAPI.DisconnectAll = func() {
		logger.Info().Msg("Disconnecting all sessions via API")
		closeAllSessions()
	}
	// Track active connections count.
	setOnSessionCountChange(func(count int) {
		localAPI.SetActiveConnections(count)
		logger.Debug().Int("count", count).Msg("Active connections updated")
	})
	if err := localAPI.Start(); err != nil {
		logger.Warn().Err(err).Msg("Failed to start local API (non-fatal)")
	} else {
		logger.Info().Msg("Local API server running on http://127.0.0.1:9876")
	}

	// Connect to signaling
	sigClient := signaling.NewClient(signalURL, deviceID, hostName, logger)
	sigClient.SetReconnect(true)

	var pendingRoomID string

	// Register for signaling events
	sigClient.On("registered", func(msg signaling.Message) {
		logger.Info().Msg("Registered with signaling server as host")
		if statusFn != nil {
			statusFn(true, "")
		}
		// Generate pairing code on registration
		go generatePairingCode(logger, signalURL, deviceID, localAPI, func(code string) {
			if statusFn != nil {
				statusFn(true, code)
			}
		})
	})

	sigClient.On("room_created", func(msg signaling.Message) {
		roomID, _ := msg.Payload["room_id"].(string)
		logger.Info().Str("room", roomID).Msg("Room created, waiting for peer to join")
		pendingRoomID = roomID
	})

	sigClient.On("peer_joined", func(msg signaling.Message) {
		peerID, _ := msg.Payload["peer_id"].(string)
		roomID, _ := msg.Payload["room_id"].(string)
		if roomID == "" {
			roomID = pendingRoomID
		}
		if peerID != "" && roomID != "" {
			logger.Info().Str("room", roomID).Str("peer", peerID).Msg("Peer joined, starting WebRTC")
			go handleIncomingConnection(logger, sigClient, roomID, peerID)
		}
		pendingRoomID = ""
	})

	sigClient.On("signal", func(msg signaling.Message) {
		if data := extractSignalData(msg); data != nil {
			routeSignal(logger, data)
		}
	})

	sigClient.On("error", func(msg signaling.Message) {
		errMsg, _ := msg.Payload["message"].(string)
		logger.Warn().Str("error", errMsg).Msg("Signaling error")
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := sigClient.Connect(ctx); err != nil {
		logger.Fatal().Err(err).Msg("Failed to connect to signaling server")
	}

	features := strings.Join([]string{"screen", "terminal", "clipboard"}, ",")
	if err := sigClient.RegisterAsHost(hostName, runtime.GOOS, runtime.GOARCH, Version, []string{features}); err != nil {
		logger.Fatal().Err(err).Msg("Failed to register as host")
	}

	logger.Info().Msg("Ready for incoming connections")
	if statusFn != nil {
		statusFn(true, "")
	}

	// Wait for shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	logger.Info().Msg("Shutting down...")
	localAPI.Stop()
	cancel()
	sigClient.Close()
}

// ─── WebRTC Session Management ──────────────────

type webrtcSession struct {
	sigClient *signaling.Client
	engine    *webrtc.Engine
	roomID    string
	hostID    string
}

func handleIncomingConnection(logger zerolog.Logger, sigClient *signaling.Client, roomID string, peerID string) {
	engine, err := webrtc.NewEngine(webrtc.EngineConfig{
		SignalClient: sigClient,
		RoomID:       roomID,
		TargetPeerID: peerID,
		ICEServers: []pion.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
			{URLs: []string{"turn:161.118.185.63:3478"}, Username: "oretty", Credential: "EZ0Er3g4Ir5T0A7vbxYf"},
		},
		Log: logger,
		OnDataChannel: func(label string, dc *pion.DataChannel) {
			handleDataChannel(logger, roomID, label, dc)
		},
		OnICEState: func(state pion.ICEConnectionState) {
			logger.Debug().Str("state", state.String()).Str("room", roomID).Msg("ICE state")
			// Auto-remove session on disconnect/failure
			if state == pion.ICEConnectionStateFailed || state == pion.ICEConnectionStateClosed {
				logger.Info().Str("room", roomID).Msg("WebRTC session closed")
				removeActiveSession(roomID)
			}
		},
		IsOfferer: true,
	})
	if err != nil {
		logger.Error().Err(err).Msg("Failed to create WebRTC engine")
		return
	}

	engine.CreateDataChannel(webrtc.DCAuth)
	engine.CreateDataChannel(webrtc.DCTerminal)
	engine.CreateDataChannel(webrtc.DCControl)
	engine.CreateDataChannel(webrtc.DCClipboard)
	engine.CreateDataChannel(webrtc.DCScreen)

	if _, err := engine.AddVideoTrack(); err != nil {
		logger.Error().Err(err).Msg("Failed to add video track")
		engine.Close()
		return
	}

	storeActiveSession(roomID, &webrtcSession{
		sigClient: sigClient,
		engine:    engine,
		roomID:    roomID,
	})

	if err := engine.CreateOffer(); err != nil {
		logger.Error().Err(err).Msg("Failed to create WebRTC offer")
		engine.Close()
		removeActiveSession(roomID)
		return
	}

	logger.Info().Str("room", roomID).Msg("WebRTC offer sent, waiting for answer...")
}

func routeSignal(logger zerolog.Logger, data map[string]interface{}) {
	session := getActiveSession()

	if session == nil {
		logger.Warn().Msg("No active session for signal")
		return
	}

	msgType, _ := data["type"].(string)
	logger.Debug().Str("signal_type", msgType).Msg("routeSignal: received signal data")

	switch msgType {
	case "answer", "ice_candidate":
		// Pass data directly — map[string]interface{} marshals to correct JSON
		// with all fields (sdp, candidate, sdpMid, etc.) intact.
		session.engine.HandleSignalingMessage(data)
	}
}

// ─── Data Channel Handlers ──────────────────────

func handleDataChannel(logger zerolog.Logger, roomID, label string, dc *pion.DataChannel) {
	logger.Info().Str("label", label).Str("room", roomID).Msg("Data channel opened")

	switch label {
	case webrtc.DCScreen:
		logger.Info().Msg("Screen data channel opened, auto-starting screen capture")
		startScreenCapture(logger)
		handleScreenControl(logger, roomID, dc)
	case webrtc.DCTerminal:
		handleTerminal(logger, roomID, dc)
	case webrtc.DCClipboard:
		handleClipboard(logger, roomID, dc)
	case webrtc.DCControl:
		handleControl(logger, roomID, dc)
	case webrtc.DCAuth:
		handleAuth(logger, roomID, dc)
	}
}

func handleScreenControl(logger zerolog.Logger, roomID string, dc *pion.DataChannel) {
	dc.OnMessage(func(msg pion.DataChannelMessage) {
		var m struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(msg.Data, &m) == nil {
			if m.Type == "screen_start" {
				startScreenCapture(logger)
			} else if m.Type == "screen_stop" {
				stopScreenCapture()
			}
		}
	})
}

var currentEnc *screen.H264Encoder

func startScreenCapture(logger zerolog.Logger) {
	if currentEnc != nil {
		return
	}
	enc, err := screen.NewH264Encoder(60, 0.9, logger)
	if err != nil {
		logger.Error().Err(err).Msg("Failed to create encoder")
		return
	}
	enc.SetHelperPath(findCaptureUtil())
	// H.264 broken — VP8 @ 60fps, 4Mbps, 720p
	enc.SetFPS(60)
	enc.SetVideoBitrate(4000)

	if err := enc.Start(func(data []byte) {
		if session := getActiveSession(); session != nil {
			session.engine.WriteVideoSample(data)
		}
	}); err != nil {
		logger.Error().Err(err).Msg("Failed to start screen capture")
		return
	}
	currentEnc = enc
	logger.Info().Msg("Screen capture started")
}

func stopScreenCapture() {
	if currentEnc != nil {
		currentEnc.Stop()
		currentEnc = nil
	}
}

func handleTerminal(logger zerolog.Logger, roomID string, dc *pion.DataChannel) {
	session, err := pty.NewSession(24, 80, logger)
	if err != nil {
		logger.Error().Err(err).Msg("Failed to create PTY")
		dc.SendText("ERROR: Shell failed")
		return
	}

	go func() {
		buf := make([]byte, 32768)
		for {
			n, err := session.Read(buf)
			if err != nil {
				break
			}
			if n > 0 {
				dc.Send(buf[:n])
			}
		}
	}()

	dc.OnMessage(func(msg pion.DataChannelMessage) {
		var m struct {
			Type    string `json:"type"`
			Payload struct {
				Rows int `json:"rows"`
				Cols int `json:"cols"`
			} `json:"payload"`
		}
		if json.Unmarshal(msg.Data, &m) == nil && m.Type == "resize" {
			session.Resize(m.Payload.Rows, m.Payload.Cols)
			return
		}
		session.Write(msg.Data)
	})
}

func handleClipboard(logger zerolog.Logger, roomID string, dc *pion.DataChannel) {
	monitor := clipboard.NewMonitor(logger)
	monitor.Start(func(text string) {
		m := map[string]interface{}{
			"type": "clipboard",
			"payload": map[string]string{"text": text},
		}
		data, _ := json.Marshal(m)
		dc.Send(data)
	})

	dc.OnMessage(func(msg pion.DataChannelMessage) {
		var m struct {
			Type    string `json:"type"`
			Payload struct {
				Text string `json:"text"`
			} `json:"payload"`
		}
		if json.Unmarshal(msg.Data, &m) == nil && m.Type == "clipboard" {
			monitor.WriteToClipboard(m.Payload.Text)
		}
	})
}

func handleControl(logger zerolog.Logger, roomID string, dc *pion.DataChannel) {
	dc.OnMessage(func(msg pion.DataChannelMessage) {
		var m struct {
			Type    string          `json:"type"`
			Payload json.RawMessage `json:"payload"`
		}
		if json.Unmarshal(msg.Data, &m) != nil {
			return
		}
		switch m.Type {
		case "mouse_move", "mouse_click", "mouse_scroll", "mouse_drag", "mouse_mode", "key_event", "unlock":
			handleInputEvent(m.Type, m.Payload)
		}
	})
}

func handleAuth(logger zerolog.Logger, roomID string, dc *pion.DataChannel) {
	dc.OnMessage(func(msg pion.DataChannelMessage) {
		var m struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(msg.Data, &m) == nil {
			if m.Type == "auth" {
				resp := map[string]interface{}{"type": "auth_ok"}
				data, _ := json.Marshal(resp)
				dc.Send(data)
			}
		}
	})
}

// ─── Global session access ─────────────────────

var (
	activeMu       sync.Mutex
	activeSessions = make(map[string]*webrtcSession)
	onSessionCount func(count int)
)

// setOnSessionCountChange sets a callback fired whenever the number of active
// sessions changes. It immediately fires with the current count.
func setOnSessionCountChange(fn func(count int)) {
	activeMu.Lock()
	defer activeMu.Unlock()
	onSessionCount = fn
	if fn != nil {
		fn(len(activeSessions))
	}
}

func storeActiveSession(roomID string, s *webrtcSession) {
	activeMu.Lock()
	activeSessions[roomID] = s
	count := len(activeSessions)
	fn := onSessionCount
	activeMu.Unlock()
	if fn != nil {
		fn(count)
	}
}

func removeActiveSession(roomID string) {
	activeMu.Lock()
	delete(activeSessions, roomID)
	count := len(activeSessions)
	fn := onSessionCount
	activeMu.Unlock()
	if fn != nil {
		fn(count)
	}
}

func getActiveSession() *webrtcSession {
	activeMu.Lock()
	defer activeMu.Unlock()
	for _, s := range activeSessions {
		return s
	}
	return nil
}

func closeAllSessions() {
	activeMu.Lock()
	sessions := activeSessions
	activeSessions = make(map[string]*webrtcSession)
	activeMu.Unlock()

	for _, s := range sessions {
		s.engine.Close()
	}

	// Notify count change
	activeMu.Lock()
	fn := onSessionCount
	activeMu.Unlock()
	if fn != nil {
		fn(0)
	}
}

func extractSignalData(msg signaling.Message) map[string]interface{} {
	data, ok := msg.Payload["data"].(map[string]interface{})
	if !ok {
		if raw, ok := msg.Payload["data"]; ok {
			if b, err := json.Marshal(raw); err == nil {
				json.Unmarshal(b, &data)
			}
		}
	}
	return data
}

// ─── Data Channel Handlers ──────────────────────

func handleInputEvent(eventType string, payload json.RawMessage) {
	switch eventType {
	case "mouse_move":
		var p struct{ X, Y float64 }
		// FIX: Add json.Unmarshal error check
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		moveMouse(p.X, p.Y)
	case "mouse_click":
		var p struct{ X, Y float64; Button int; Down bool }
		// FIX: Add json.Unmarshal error check
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		clickMouse(p.Button, p.Down, p.X, p.Y)
	case "mouse_scroll":
		var p struct{ DeltaX, DeltaY float64 }
		// FIX: Add json.Unmarshal error check
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		scrollMouse(p.DeltaX, p.DeltaY)
	case "mouse_drag":
		// FIX: Handle mouse drag events (start/move/end)
		var p struct {
			Type    string  `json:"type"`
			X, Y    float64
		}
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		switch p.Type {
		case "start":
			clickMouse(0, true, p.X, p.Y)
		case "move":
			moveMouse(p.X, p.Y)
		case "end":
			clickMouse(0, false, p.X, p.Y)
		}
	case "key_event":
		var p struct{ Key, Code string; Modifiers []string; Down bool }
		// FIX: Add json.Unmarshal error check
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		sendKey(p.Key, p.Code, p.Modifiers, p.Down)
	case "unlock":
		var p struct{ Password string }
		// FIX: Add json.Unmarshal error check
		if err := json.Unmarshal(payload, &p); err != nil {
			return
		}
		unlockMac(p.Password)
	case "mouse_mode":
		var p struct{ Mode string }
		if json.Unmarshal(payload, &p) == nil && p.Mode != "" {
			log.Printf("[INFO] Mouse mode changed to: %s", p.Mode)
		}
	}
}

// ─── Device ID ──────────────────────────────────

func getDeviceID() string {
	idFile := os.ExpandEnv("$HOME/.oretty/device_id")
	if data, err := os.ReadFile(idFile); err == nil && len(data) > 0 {
		return strings.TrimSpace(string(data))
	}
	id := uuid.New().String()
	os.MkdirAll(os.ExpandEnv("$HOME/.oretty"), 0755)
	os.WriteFile(idFile, []byte(id), 0644)
	return id
}

// ─── Capture Util Path ──────────────────────────

func findCaptureUtil() string {
	paths := []string{
		"./bin/captureutil",
		"/usr/local/lib/oretty/captureutil",
		"/opt/homebrew/lib/oretty/captureutil",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// ─── Pairing Code Generation ────────────────────

func generatePairingCode(logger zerolog.Logger, signalURL, deviceID string, localAPI *api.LocalAPIServer, onCode func(string)) {
	baseURL := strings.TrimSuffix(signalURL, "/ws")
	baseURL = strings.TrimRight(baseURL, "/")
	if !strings.HasPrefix(baseURL, "http") {
		if strings.HasPrefix(baseURL, "wss://") {
			baseURL = "https://" + strings.TrimPrefix(baseURL, "wss://")
		} else {
			baseURL = "http://" + strings.TrimPrefix(baseURL, "ws://")
		}
	}

	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
		Timeout: 10 * time.Second,
	}

	body := fmt.Sprintf(`{"device_id":"%s","host_id":"%s"}`, deviceID, deviceID)
	resp, err := client.Post(baseURL+"/api/pair/generate", "application/json",
		bytes.NewBufferString(body))
	if err != nil {
		logger.Warn().Err(err).Msg("Failed to generate pairing code")
		return
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	var result struct {
		Success bool   `json:"success"`
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil || !result.Success {
		logger.Warn().Str("response", string(respBody)).Msg("Failed to generate pairing code")
		return
	}

	logger.Info().Str("code", result.Code).Msg("Pairing code generated")
	localAPI.SetPairCode(result.Code)
	if onCode != nil {
		onCode(result.Code)
	}
}
