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