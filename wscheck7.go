package main

import (
	"fmt"
	"time"
	"github.com/gorilla/websocket"
)

func main() {
	// Test with a public WebSocket echo server
	conn, _, err := websocket.DefaultDialer.Dial("wss://echo.websocket.org", nil)
	if err != nil {
		fmt.Println("DIAL ERROR:", err)
		return
	}
	defer conn.Close()
	fmt.Println("Connected to echo.websocket.org at", time.Now().Format("15:04:05"))
	
	conn.WriteMessage(websocket.TextMessage, []byte("hello"))
	_, msg, _ := conn.ReadMessage()
	fmt.Println("Echo:", string(msg))
	
	done := make(chan struct{})
	go func() {
		for {
			_, _, err := conn.ReadMessage()
			if err != nil {
				fmt.Println("READ ERROR:", err, "at", time.Now().Format("15:04:05"))
				close(done)
				return
			}
		}
	}()
	
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		fmt.Println("Still alive after 15s!")
	}
}
