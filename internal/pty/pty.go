// Package pty manages PTY sessions for remote terminal access on macOS.
package pty

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
	"github.com/rs/zerolog"
)

// Session represents a PTY session.
type Session struct {
	file   *os.File
	cmd    *exec.Cmd
	mu     sync.Mutex
	rows   int
	cols   int
	log    zerolog.Logger
	closed bool
}

// NewSession creates a new PTY session with the given size.
func NewSession(rows, cols int, log zerolog.Logger) (*Session, error) {
	if rows <= 0 {
		rows = 24
	}
	if cols <= 0 {
		cols = 80
	}

	// Start shell with PTY
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}

	cmd := exec.Command(shell)
	cmd.Env = append(os.Environ(),
		"TERM=xterm-256color",
		fmt.Sprintf("LINES=%d", rows),
		fmt.Sprintf("COLUMNS=%d", cols),
	)

	f, err := pty.StartWithSize(cmd, &pty.Winsize{