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
	conn, _, err := dialer.Dial(u.String(), nil)
	if err != nil {
		fmt.Println("DIAL ERROR:", err)
		return
	}
	defer conn.Close()
	fmt.Println("Connected at", time.Now().Format("15:04:05"))
	
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
	case <-time.After(20 * time.Second):
		fmt.Println("Still alive after 20s!")
	}
}
