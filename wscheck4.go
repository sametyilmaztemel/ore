package main

import (
	"fmt"
	"net/url"
	"time"
	"github.com/gorilla/websocket"
)

func main() {
	// Try without TLS via localhost (orettyd's local API doesn't do WebSocket)
	// Actually, try a different WebSocket server to isolate the issue
	u, _ := url.Parse("ws://echo.websocket.org")
	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		fmt.Println("DIAL ERROR (echo):", err)
		// Try our signaling server without TLS
		fmt.Println("Trying signaling server...")
	}
	_ = conn
	fmt.Println("Test done")
}
