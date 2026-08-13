package main

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
	"github.com/gorilla/websocket"
)

func main() {
	u, _ := url.Parse("wss://161.118.185.63:443")
	u.Path = "/ws"
	
	// Manually dial TCP + TLS
	tcpConn, err := net.DialTimeout("tcp", u.Host, 10*time.Second)
	if err != nil {
		fmt.Println("TCP ERROR:", err)
		return
	}
	
	tlsConn := tls.Client(tcpConn, &tls.Config{InsecureSkipVerify: true})
	err = tlsConn.Handshake()
	if err != nil {
		fmt.Println("TLS ERROR:", err)
		return
	}
	fmt.Println("TLS OK, ALPN:", tlsConn.ConnectionState().NegotiatedProtocol)
	
	// Use gorilla's NewClient to do the WebSocket upgrade on our TLS connection
	conn, resp, err := websocket.NewClient(tlsConn, u, http.Header{
		"Origin": {"https://161.118.185.63:443"},
	}, 1024, 1024)
	if err != nil {
		fmt.Println("NEWCLIENT ERROR:", err)
		if resp != nil {
			fmt.Println("Response:", resp.Status)
		}
		return
	}
	defer conn.Close()
	fmt.Println("Connected! Status:", resp.Status)
	
	// Read loop
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
