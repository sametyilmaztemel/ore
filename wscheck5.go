package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

func main() {
	u, _ := url.Parse("wss://161.118.185.63:443")
	u.Path = "/ws"
	
	tlsConfig := &tls.Config{InsecureSkipVerify: true}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	
	conn, err := tls.DialWithDialer(dialer, "tcp", u.Host, tlsConfig)
	if err != nil {
		fmt.Println("TLS ERROR:", err)
		return
	}
	defer conn.Close()
	fmt.Println("TLS connected")
	
	// Send HTTP upgrade request manually
	req := "GET /ws HTTP/1.1\r\nHost: 161.118.185.63:443\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, err = conn.Write([]byte(req))
	if err != nil {
		fmt.Println("WRITE ERROR:", err)
		return
	}
	fmt.Println("Request sent")
	
	// Read response
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		fmt.Println("READ RESPONSE ERROR:", err)
		return
	}
	fmt.Printf("Response: %s\n", resp.Status)
	
	if resp.StatusCode == 101 {
		fmt.Println("WebSocket upgrade OK! Connection will stay open...")
		// Keep connection alive
		conn.SetReadDeadline(time.Now().Add(15 * time.Second))
		buf := make([]byte, 1024)
		n, err := conn.Read(buf)
		if err != nil {
			fmt.Printf("Read after upgrade: %v (after %.0fs)\n", err, 15)
		} else {
			fmt.Printf("Got data: %s\n", string(buf[:n]))
		}
	} else {
		body := make([]byte, 1024)
		n, _ := conn.Read(body)
		fmt.Printf("Body: %s\n", string(body[:n]))
	}
}
