// Package screen implements macOS screen capture using a native helper binary.
package screen

import (
	"encoding/binary"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// H264Encoder handles hardware-accelerated H.264 encoding of the Mac screen
// by running a native helper that uses ScreenCaptureKit + VideoToolbox.
type H264Encoder struct {
	mu          sync.Mutex
	width       int
	height      int
	fps         int
	bitrate     int // kbps
	callback    func([]byte)
	cmd         *exec.Cmd
	stdout      io.ReadCloser
	stopCh      chan struct{}
	running     bool
	log         zerolog.Logger
	frameCount  int
	lastLogTime time.Time
	helperPath  string

	// Access unit buffer: accumulates NAL units with Annex-B start codes (0x00000001)
	// and flushes them as a complete access unit (one frame) when a VCL NAL arrives.
	// This ensures all NALs for one frame share the same RTP timestamp.
	ancBuf []byte
}

// NewH264Encoder creates a new H.264 screen encoder.
func NewH264Encoder(fps int, quality float64, log zerolog.Logger) (*H264Encoder, error) {
	if fps <= 0 {
		fps = 30
	}
	if quality <= 0 {
		quality = 0.7
	}

	// Find the helper binary
	helperPath := ""
	paths := []string{
		"/usr/local/lib/oretty/captureutil",
		"/opt/homebrew/lib/oretty/captureutil",
		"./captureutil",
	}

	for _, p := range paths {
		// We'll build from source at first run
		_ = p
	}

	return &H264Encoder{
		fps:         fps,
		stopCh:      make(chan struct{}),
		log:         log.With().Str("component", "screen").Logger(),
		lastLogTime: time.Now(),
		helperPath:  helperPath,
	}, nil
}

// SetHelperPath sets a custom path for the capture helper binary.
func (e *H264Encoder) SetHelperPath(path string) {
	e.helperPath = path
}

// SetFPS sets the target frame rate.
func (e *H264Encoder) SetFPS(fps int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.fps = fps
}

// SetVideoBitrate sets the video bitrate in kbps.
func (e *H264Encoder) SetVideoBitrate(kbps int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.bitrate = kbps
}

// Start begins capturing and encoding the screen.
func (e *H264Encoder) Start(callback func([]byte)) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.running {
		return fmt.Errorf("already running")
	}

	e.callback = callback

	// Detect display size
	width, height, err := getDisplaySize()
	if err != nil {
		return fmt.Errorf("get display size: %w", err)
	}
	e.width = width
	e.height = height

	e.mu.Unlock()
	errBuild := e.buildAndStart()
	e.mu.Lock()

	if errBuild != nil {
		return fmt.Errorf("start capture: %w", errBuild)
	}

	e.running = true

	e.log.Info().
		Int("width", e.width).Int("height", e.height).
		Int("fps", e.fps).Str("helper", e.helperPath).
		Msg("Screen capture started with H.264 encoding via captureutil")
	return nil
}

// Stop stops the capture and encoding.
func (e *H264Encoder) Stop() {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return
	}
	e.running = false
	close(e.stopCh)

	if e.cmd != nil && e.cmd.Process != nil {
		e.cmd.Process.Kill()
		e.cmd.Wait()
	}
	e.cmd = nil
	e.stdout = nil

	e.log.Info().Msg("Screen capture stopped")
}

func (e *H264Encoder) buildAndStart() error {
	// Real screen capture via ffmpeg avfoundation + VP8
	return e.startFFmpegCapture()
}

func (e *H264Encoder) startFFmpegCapture() error {
	ffmpegPath, err := exec.LookPath("ffmpeg")
	if err != nil {
		return fmt.Errorf("ffmpeg not found: %w", err)
	}

	// Detect screen input index
	screenIndex := e.getScreenInputIndex(ffmpegPath)

	// Use display dimensions (capped to reasonable streaming size)
	width := e.width
	height := e.height
	if width <= 0 || height <= 0 {
		width, height = 1280, 720
	}
	// Keep aspect ratio but cap at 1280x720 for streaming
	if width > 1280 {
		width = 1280
		height = height * 1280 / e.width
	}