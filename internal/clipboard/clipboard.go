// Package clipboard manages bidirectional clipboard synchronization.
package clipboard

import (
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// Monitor observes clipboard changes and triggers callbacks.
type Monitor struct {
	mu         sync.Mutex
	onChange   func(text string)
	running    bool
	stopCh     chan struct{}
	lastText   string
	checkInterval time.Duration
	log        zerolog.Logger
}

// NewMonitor creates a new clipboard monitor.
func NewMonitor(log zerolog.Logger) *Monitor {
	return &Monitor{
		stopCh:        make(chan struct{}),
		checkInterval: 500 * time.Millisecond,
		log:           log.With().Str("component", "clipboard").Logger(),
	}
}

// Start begins monitoring clipboard changes.
func (m *Monitor) Start(onChange func(text string)) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.running {
		return nil
	}

	m.onChange = onChange
	m.running = true
	m.lastText = m.readClipboard()

	go m.loop()
	m.log.Info().Msg("Clipboard monitor started")
	return nil
}

// Stop stops monitoring.
func (m *Monitor) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()

	if !m.running {
		return
	}
	m.running = false
	close(m.stopCh)
	m.log.Info().Msg("Clipboard monitor stopped")
}

// WriteToClipboard writes text to the system clipboard.
func (m *Monitor) WriteToClipboard(text string) error {
	return writeClipboard(text)
}

// ReadClipboard reads the current clipboard text.
func (m *Monitor) ReadClipboard() (string, error) {
	return m.readClipboard(), nil
}

func (m *Monitor) loop() {
	ticker := time.NewTicker(m.checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-m.stopCh:
			return
		case <-ticker.C:
			current := m.readClipboard()
			if current != m.lastText {
				oldText := m.lastText
				m.lastText = current
				if m.onChange != nil && current != "" {
					m.log.Debug().Int("bytes", len(current)).Msg("Clipboard changed")
					m.onChange(current)
				}
				_ = oldText
			}
		}
	}
}

func (m *Monitor) readClipboard() string {
	return readClipboard()
}
