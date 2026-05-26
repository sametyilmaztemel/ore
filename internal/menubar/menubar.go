// Package menubar provides the macOS menu bar integration for orettyd.
package menubar

import (
	"fmt"
	"os/exec"
	"sync"

	"github.com/getlantern/systray"
	"github.com/rs/zerolog"
)

// Menu items
var (
	menuStatus    *systray.MenuItem
	menuPairCode  *systray.MenuItem
	menuCopyCode  *systray.MenuItem
	menuDevices   *systray.MenuItem
	menuQuit      *systray.MenuItem
)

var (
	log       zerolog.Logger
	mu        sync.Mutex
	curCode   string
	onQuit    func()
)

// SetLogger sets the logger for the menu bar.
func SetLogger(l zerolog.Logger) {
	log = l.With().Str("component", "menubar").Logger()
}

// SetOnQuit sets the callback for when the user clicks Quit.
func SetOnQuit(fn func()) {
	onQuit = fn
}

// OnReady is called by systray.Run when the menu bar is ready.
func OnReady() {
	systray.SetTitle("O")
	systray.SetTooltip("Oretty - Remote Mac Access")

	menuStatus = systray.AddMenuItem("○ Disconnected", "Connection status")
	menuStatus.Disable()

	menuPairCode = systray.AddMenuItem("Pairing Code: ------", "Current pairing code")
	menuPairCode.Disable()

	menuCopyCode = systray.AddMenuItem("📋 Copy Pairing Code", "Copy to clipboard")

	menuDevices = systray.AddMenuItem("No devices connected", "Connected devices")
	menuDevices.Disable()

	systray.AddSeparator()
	menuQuit = systray.AddMenuItem("Quit", "Quit Oretty")

	// Event handlers
	go func() {
		for range menuCopyCode.ClickedCh {
			copyToClipboard(curCode)
		}
	}()

	go func() {
		<-menuQuit.ClickedCh
		if onQuit != nil {
			onQuit()
		}
		systray.Quit()
	}()
}

// OnExit is called when the systray exits.
func OnExit() {}

// UpdateStatus updates the connection status and pairing code display.
func UpdateStatus(connected bool, code string) {
	mu.Lock()
	defer mu.Unlock()

	if menuStatus == nil {
		return
	}

	curCode = code

	if connected {
		menuStatus.SetTitle("● Connected")
		systray.SetTooltip("Oretty - Connected")
	} else {
		menuStatus.SetTitle("○ Disconnected")
		systray.SetTooltip("Oretty - Disconnected")
	}

	if code != "" {
		menuPairCode.SetTitle("Pairing Code: " + code)
	}
}

// UpdateDevices updates the connected devices count.
func UpdateDevices(count int) {
	mu.Lock()
	defer mu.Unlock()

	if menuDevices == nil {
		return
	}

	if count == 0 {
		menuDevices.SetTitle("No devices connected")
	} else if count == 1 {
		menuDevices.SetTitle("1 device connected")
	} else {
		menuDevices.SetTitle(fmt.Sprintf("%d devices connected", count))
	}
}

func copyToClipboard(text string) {
	if text == "" {
		return
	}
	cmd := exec.Command("pbcopy")
	w, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	go func() {
		defer w.Close()
		w.Write([]byte(text))
	}()
	cmd.Run()
}
