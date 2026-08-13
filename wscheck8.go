package main

import (
	"crypto/tls"
	"fmt"
	"net/url"
	"time"
	"github.com/gorilla/websocket"
)

func main() {
	u, _ := url.Parse("wss://161.118.185.63:443")
	u.Path = "/ws"
	
	// First check TLS with OpenSSL-style config
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true,
	}
	
	// Connect using gorilla/websocket but with custom NetDial that logs TLS state
	dialer := websocket.DefaultDialer
	dialer.TLSClientConfig = tlsConfig
	
	conn, resp, err := dialer.Dial(u.String(), nil)
	if err != nil {
		fmt.Println("DIAL ERROR:", err)
		if resp != nil {
			fmt.Println("Status:", resp.Status)
		}
		return
	}
	defer conn.Close()
	fmt.Println("Dial OK, Status:", resp.Status)
	
	// Check if there's any TLS state available
	fmt.Println("Sending register...")
	err = conn.WriteJSON(map[string]interface{}{
		"type": "register",
		"payload": map[string]interface{}{
			"device_id": "gorilla-test",
			"is_host":   false,
		},
	})
	if err != nil {
		fmt.Println("WRITE ERROR:", err)
		return
	}
	fmt.Println("Register sent")
	
	done := make(chan struct{})
	go func() {
		for {
			_, msg, err := conn.ReadMessage()
			if err != nil {
				fmt.Println("READ ERROR:", err, "at", time.Now().Format("15:04:05"))
				close(done)
				return
			}
			fmt.Println("MSG:", string(msg))
		}
	}()
	
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		fmt.Println("Still alive after 15s!")
	}
}
