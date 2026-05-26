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