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
	dialer := websocket.DefaultDialer
	dialer.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	
	for i := 0; i < 5; i++ {
		conn, _, err := dialer.Dial(u.String(), nil)
		if err != nil {
			fmt.Println("DIAL ERROR:", err)
			return
		}
		
		fmt.Printf("Conn %d: Connected at %s\n", i+1, time.Now().Format("15:04:05"))
		
		done := make(chan struct{})
		start := time.Now()
		go func() {
			for {
				_, _, err := conn.ReadMessage()
				if err != nil {
					fmt.Printf("Conn %d: READ ERROR: %v at %s (elapsed: %.0fs)\n", i+1, err, time.Now().Format("15:04:05"), time.Since(start).Seconds())
					close(done)
					return
				}
			}
		}()
		
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			fmt.Printf("Conn %d: Still alive after 10s!\n", i+1)
		}
		conn.Close()
		time.Sleep(1 * time.Second)
	}
}
