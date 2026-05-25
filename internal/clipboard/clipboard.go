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