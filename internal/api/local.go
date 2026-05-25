// Package api provides a local HTTP API for the MenuBar app.
package api

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sync"
)

// LocalAPIServer handles localhost-only HTTP endpoints for the MenuBar.
type LocalAPIServer struct {
	server   *http.Server
	mu       sync.RWMutex
	pairCode string
	hostName string
	deviceID string
	activeConnections int
	// RefreshCode is called when the menu bar requests a new pairing code.
	// Set by main.go at startup.
	RefreshCode func()
	// DisconnectAll is called when the menu bar requests disconnecting all devices.
	// Set by main.go at startup.
	DisconnectAll func()
}

// NewLocalAPIServer creates a local API server.
func NewLocalAPIServer(hostName, deviceID string) *LocalAPIServer {
	s := &LocalAPIServer{
		hostName: hostName,
		deviceID: deviceID,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/paircode", s.handlePairCode)
	mux.HandleFunc("/api/paircode/refresh", s.handlePairCodeRefresh)
	mux.HandleFunc("/api/disconnect", s.handleDisconnect)

	s.server = &http.Server{
		Handler: mux,
	}
	return s
}

// Start begins listening on localhost:9876.
func (s *LocalAPIServer) Start() error {
	listener, err := net.Listen("tcp", "127.0.0.1:9876")
	if err != nil {
		return fmt.Errorf("local API listen: %w", err)
	}
	go s.server.Serve(listener)
	return nil
}

// Stop shuts down the local API server.
func (s *LocalAPIServer) Stop() {
	if s.server != nil {
		s.server.Close()
	}
}

// SetPairCode updates the current pairing code.
func (s *LocalAPIServer) SetPairCode(code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pairCode = code
}

// SetActiveConnections updates the count of connected devices.
func (s *LocalAPIServer) SetActiveConnections(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.activeConnections = n
}

type StatusResponse struct {
	HostName    string `json:"host_name"`
	DeviceID    string `json:"device_id"`
	DaemonRunning bool `json:"daemon_running"`
	PairCode    string `json:"pair_code"`
	Connected   int    `json:"connected_devices"`
}

type PairCodeResponse struct {
	Code string `json:"code"`
}

func (s *LocalAPIServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	s.mu.RLock()
	code := s.pairCode
	connCount := s.activeConnections
	s.mu.RUnlock()

	json.NewEncoder(w).Encode(StatusResponse{
		HostName:      s.hostName,
		DeviceID:      s.deviceID,
		DaemonRunning: true,
		PairCode:      code,
		Connected:     connCount,
	})
}

func (s *LocalAPIServer) handlePairCode(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	s.mu.RLock()
	code := s.pairCode
	s.mu.RUnlock()

	json.NewEncoder(w).Encode(PairCodeResponse{Code: code})
}

// handlePairCodeRefresh generates a new pairing code.
// Only accepts POST requests.
func (s *LocalAPIServer) handlePairCodeRefresh(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	if s.RefreshCode == nil {
		http.Error(w, `{"error":"refresh not available"}`, http.StatusServiceUnavailable)
		return
	}
	s.RefreshCode()
	s.mu.RLock()
	code := s.pairCode
	s.mu.RUnlock()
	json.NewEncoder(w).Encode(PairCodeResponse{Code: code})
}

// handleDisconnect disconnects all connected devices.
// Only accepts POST requests.
func (s *LocalAPIServer) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	if s.DisconnectAll == nil {
		http.Error(w, `{"error":"disconnect not available"}`, http.StatusServiceUnavailable)
		return
	}
	s.DisconnectAll()
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}
