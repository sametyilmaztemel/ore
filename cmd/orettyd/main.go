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