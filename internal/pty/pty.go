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
		Rows: uint16(rows),
		Cols: uint16(cols),
		X:    0,
		Y:    0,
	})
	if err != nil {
		return nil, fmt.Errorf("start PTY: %w", err)
	}

	s := &Session{
		file: f,
		cmd:  cmd,
		rows: rows,
		cols: cols,
		log:  log.With().Str("component", "pty").Logger(),
	}

	s.log.Info().Int("rows", rows).Int("cols", cols).Str("shell", shell).Msg("PTY session started")
	return s, nil
}

// Read reads from the PTY. Implements io.Reader.
func (s *Session) Read(buf []byte) (int, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return 0, io.EOF
	}
	s.mu.Unlock()

	return s.file.Read(buf)
}

// Write writes to the PTY. Implements io.Writer.
func (s *Session) Write(data []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return 0, io.EOF
	}
	return s.file.Write(data)
}

// Resize changes the terminal dimensions.
func (s *Session) Resize(rows, cols int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return fmt.Errorf("session closed")
	}

	if err := pty.Setsize(s.file, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	}); err != nil {
		return fmt.Errorf("resize: %w", err)
	}

	s.rows = rows
	s.cols = cols
	return nil
}

// Close closes the PTY session.
func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return nil
	}
	s.closed = true

	if s.cmd != nil && s.cmd.Process != nil {
		s.cmd.Process.Kill()
		s.cmd.Wait()
	}

	err := s.file.Close()
	s.log.Info().Msg("PTY session closed")
	return err
}

// Rows returns the number of rows.
func (s *Session) Rows() int { return s.rows }

// Cols returns the number of columns.
func (s *Session) Cols() int { return s.cols }

// IsClosed returns whether the session is closed.
func (s *Session) IsClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}
