package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sametyilmaztemel/ore/server/signaling"
)

var (
	upgrader = websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin: func(r *http.Request) bool {
			return true // Allow all origins for WebSocket connections
		},
	}

	hub   *signaling.Hub
	db    *signaling.Database
	mu    sync.RWMutex
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Println("Oretty Signaling Server starting...")

	// Load configuration
	port := getEnv("SIGNAL_PORT", "443")
	certFile := getEnv("TLS_CERT", "cert.pem")
	keyFile := getEnv("TLS_KEY", "key.pem")
	dbPath := getEnv("DB_PATH", "oretty.db")

	// Initialize database
	var err error
	db, err = signaling.NewDatabase(dbPath)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()
	log.Printf("Database initialized at %s", dbPath)

	// Initialize hub
	hub = signaling.NewHub(db)
	go hub.Run()

	// HTTP endpoints
	http.HandleFunc("/ws", handleWebSocket)
	http.HandleFunc("/api/pair", handlePairing)
	http.HandleFunc("/api/pair/generate", handleGeneratePairing)
	http.HandleFunc("/api/hosts", handleListHosts)
	http.HandleFunc("/health", handleHealth)

	// Create HTTPS server with HTTP/2 disabled (WebSocket needs HTTP/1.1)
	server := &http.Server{
		Addr:         fmt.Sprintf(":%s", port),
		Handler:      nil,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("Signaling server listening on WSS :%s", port)
		if certFile != "" && keyFile != "" {
			if fileExists(certFile) && fileExists(keyFile) {
				log.Printf("Using TLS with cert=%s key=%s", certFile, keyFile)
				if err := server.ListenAndServeTLS(certFile, keyFile); err != nil && err != http.ErrServerClosed {
					log.Fatalf("TLS server error: %v", err)
				}
				return
			}
		}
		log.Println("TLS certificates not found, falling back to plain WebSocket (NOT secure!)")
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	<-stop
	log.Println("Shutting down gracefully...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	hub.Stop()
	server.Shutdown(shutdownCtx)
	log.Println("Server stopped.")
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}

	client := signaling.NewClient(conn, hub, db)
	hub.Register <- client

	go client.WritePump()
	go client.ReadPump()
}

type PairRequest struct {
	Code string `json:"code"`
}

type PairResponse struct {
	Success  bool   `json:"success"`
	DeviceID string `json:"device_id,omitempty"`
	HostID   string `json:"host_id,omitempty"`
	RoomID   string `json:"room_id,omitempty"`
	Message  string `json:"message,omitempty"`
}

func handlePairing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		json.NewEncoder(w).Encode(PairResponse{
			Success: false,
			Message: "Method not allowed",
		})
		return
	}

	var req PairRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		json.NewEncoder(w).Encode(PairResponse{
			Success: false,
			Message: "Invalid request body",
		})
		return
	}

	deviceID, hostID, err := hub.VerifyPairingCode(req.Code)
	if err != nil {
		json.NewEncoder(w).Encode(PairResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}

	// Auto-create a room for the host after successful pairing
	hostClient := hub.GetHostClient(hostID)
	var roomID string
	if hostClient != nil {
		room := hub.CreateRoom(hostClient, "paired-"+hostID)
		roomID = room.ID
		log.Printf("Room created for host %s: %s", hostID, roomID)

		// Notify the host that a room was created (triggers WebRTC)
		hub.NotifyHostRoomCreated(hostID, roomID, room.Name)
	} else {
		log.Printf("Warning: Host %s not found for room creation", hostID)
	}

	json.NewEncoder(w).Encode(PairResponse{
		Success:  true,
		DeviceID: deviceID,
		HostID:   hostID,
		RoomID:   roomID,
		Message:  "Pairing successful",
	})
}

func handleListHosts(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	hosts := hub.ListActiveHosts()
	json.NewEncoder(w).Encode(map[string]interface{}{
		"hosts": hosts,
		"count": len(hosts),
	})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":    "ok",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
		"hosts":     hub.ActiveHostCount(),
		"rooms":     hub.ActiveRoomCount(),
	})
}

type GeneratePairRequest struct {
	DeviceID string `json:"device_id"`
	HostID   string `json:"host_id"`
}

func handleGeneratePairing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": false,
			"message": "Method not allowed",
		})
		return
	}

	var req GeneratePairRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": false,
			"message": "Invalid request body",
		})
		return
	}

	if req.DeviceID == "" || req.HostID == "" {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": false,
			"message": "device_id and host_id are required",
		})
		return
	}

	code := hub.GeneratePairingCode(req.DeviceID, req.HostID)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"code":    code,
		"message": "Pairing code generated",
	})
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
