package main

import (
	"context"
	"fmt"
	"time"
	"github.com/rs/zerolog"
	"github.com/sametyilmaztemel/ore/internal/signaling"
)

func main() {
	logger := zerolog.New(zerolog.ConsoleWriter{Out: zerolog.NewConsoleWriter().Out}).With().Timestamp().Logger()
	
	client := signaling.NewClient("wss://161.118.185.63:443", "test-device-97", "TestHost", logger)
	client.SetReconnect(false)
	
	client.On("registered", func(msg signaling.Message) {
		fmt.Println("Registered event received!")
	})
	
	err := client.Connect(context.Background())
	if err != nil {
		fmt.Println("CONNECT ERROR:", err)
		return
	}
	fmt.Println("Connected!")
	
	err = client.RegisterAsHost("TestHost", "darwin", "arm64", "dev", nil)
	if err != nil {
		fmt.Println("REGISTER ERROR:", err)
		return
	}
	fmt.Println("Registered as host!")
	
	time.Sleep(15 * time.Second)
	fmt.Println("Still alive after 15s!")
	
	client.Close()
}
