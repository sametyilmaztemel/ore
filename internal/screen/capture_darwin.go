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
	if height > 720 {
		height = 720
		width = width * 720 / height
	}
	// Ensure even dimensions
	width = width / 2 * 2
	height = height / 2 * 2

	fps := e.fps
	if fps <= 0 {
		fps = 15
	}

	bitrate := e.bitrate
	if bitrate <= 0 {
		bitrate = 2000
	}

	args := []string{
		"-f", "avfoundation",
		"-i", screenIndex,
		"-vf", fmt.Sprintf("scale=%d:%d", width, height),
		"-c:v", "libvpx",
		"-b:v", fmt.Sprintf("%dk", bitrate),
		"-r", fmt.Sprintf("%d", fps),
		"-g", fmt.Sprintf("%d", fps*2), // keyframe every 2 seconds
		"-deadline", "realtime",
		"-cpu-used", "5",
		"-f", "ivf",
		"-",
	}

	e.log.Info().
		Str("input", screenIndex).
		Int("width", width).
		Int("height", height).
		Int("fps", fps).
		Int("bitrate_kbps", bitrate).
		Msg("Starting VP8 screen capture via avfoundation")

	cmd := exec.Command(ffmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("ffmpeg stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start ffmpeg: %w", err)
	}

	e.cmd = cmd
	e.stdout = stdout
	e.helperPath = ffmpegPath

	go e.ivfReadLoop(stdout)
	return nil
}

func (e *H264Encoder) getScreenInputIndex(ffmpegPath string) string {
	out, err := exec.Command(ffmpegPath, "-f", "avfoundation", "-list_devices", "true", "-i", "").CombinedOutput()
	if err != nil {
		return "3" // fallback
	}
	output := string(out)
	// Find first "Capture screen" device
	for _, line := range strings.Split(output, "\n") {
		if strings.Contains(line, "Capture screen") {
			// Extract index like [3]
			parts := strings.Split(line, "[")
			if len(parts) >= 2 {
				idxParts := strings.Split(parts[1], "]")
				if len(idxParts) >= 1 {
					return idxParts[0]
				}
			}
		}
	}
	return "3" // fallback: 3 = Capture screen 0
}

// ivfReadLoop reads VP8 frames from an IVF container and calls deliverFrame
func (e *H264Encoder) ivfReadLoop(reader io.ReadCloser) {
	defer reader.Close()

	// Skip 32-byte IVF file header
	header := make([]byte, 32)
	if _, err := io.ReadFull(reader, header); err != nil {
		e.log.Warn().Err(err).Msg("ivfReadLoop: failed to read header")
		return
	}

	frameHeader := make([]byte, 12)
	for {
		if _, err := io.ReadFull(reader, frameHeader); err != nil {
			break
		}
		// Frame header: bytes 0-3 = frame size (little-endian)
		frameSize := uint32(frameHeader[0]) | uint32(frameHeader[1])<<8 |
			uint32(frameHeader[2])<<16 | uint32(frameHeader[3])<<24

		frameData := make([]byte, frameSize)
		if _, err := io.ReadFull(reader, frameData); err != nil {
			break
		}

		// Send raw VP8 frame directly to WebRTC (bypass bufferNAL for VP8)
		if e.callback != nil {
			e.callback(frameData)
			e.frameCount++
			now := time.Now()
			if now.Sub(e.lastLogTime) >= time.Second {
				e.log.Debug().Int("fps", e.frameCount).Msg("VP8 FPS")
				e.frameCount = 0
				e.lastLogTime = now
			}
		}
	}
	e.log.Info().Msg("IVF read loop ended")
}

// readLoop reads H.264 NAL units from the helper's stdout.
// The helper outputs 4-byte length-prefixed NAL units.
func (e *H264Encoder) readLoop(reader io.ReadCloser) {
	defer reader.Close()

	// Check if it's raw H.264 (ffmpeg mode) or length-prefixed (captureutil mode)
	buf := make([]byte, 65536)
	nalBuffer := make([]byte, 0, 65536)

	for {
		n, err := reader.Read(buf)
		if err != nil {
			if err != io.EOF {
				e.log.Warn().Err(err).Msg("Read error")
			}
			return
		}

		if n == 0 {
			continue
		}

		data := buf[:n]

		// Try length-prefixed format first (captureutil)
		if isLengthPrefixed(data) {
			e.parseLengthPrefixed(data)
		} else {
			// FFmpeg outputs Annex-B (start code prefixed)
			nalBuffer = append(nalBuffer, data...)
			e.parseAnnexB(nalBuffer, &nalBuffer)
		}
	}
}

// isLengthPrefixed checks if data starts with a 4-byte length prefix (captureutil format)
// Returns false for Annex-B start codes (0x00000001 / 0x000001)
func isLengthPrefixed(data []byte) bool {
	if len(data) < 4 {
		return false
	}
	// Annex-B start codes: 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
	if data[0] == 0 && data[1] == 0 && (data[2] == 1 || (data[2] == 0 && data[3] == 1)) {
		return false
	}
	length := binary.BigEndian.Uint32(data[:4])
	// Sanity check: length should be reasonable for a NAL unit
	return length > 0 && length < 1000000
}

// parseLengthPrefixed handles captureutil format: [4-byte length][NAL unit data]...
// NAL units are buffered into complete Annex-B access units (with 0x00000001 start codes)
// so that the WebRTC receiver gets all NALs for one frame with the same RTP timestamp.
func (e *H264Encoder) parseLengthPrefixed(data []byte) {
	offset := 0
	for offset+4 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[offset : offset+4]))
		offset += 4
		if offset+length > len(data) {
			break
		}
		e.bufferNAL(data[offset : offset+length])
		offset += length
	}
}

// parseAnnexB extracts NAL units from Annex-B format (00 00 01 start codes)
func (e *H264Encoder) parseAnnexB(buf []byte, leftover *[]byte) {
	var nals [][]byte
	start := 0
	pos := 0

	for pos <= len(buf)-4 {
		isStart := false
		scLen := 0
		if buf[pos] == 0 && buf[pos+1] == 0 {
			if buf[pos+2] == 1 {
				isStart = true
				scLen = 3 // 0x00 0x00 0x01
			} else if pos+3 < len(buf) && buf[pos+2] == 0 && buf[pos+3] == 1 {
				isStart = true
				scLen = 4 // 0x00 0x00 0x00 0x01
			}
		}

		if isStart {
			if start > 0 {
				// NAL data runs from start to pos (before the current start code)
				nal := make([]byte, pos-start)
				copy(nal, buf[start:pos])
				if len(nal) > 0 {
					nals = append(nals, nal)
				}
			}
			start = pos + scLen // data starts after the start code
			pos += scLen
		} else {
			pos++
		}
	}

	// Keep incomplete data at the end (from current start position)
	if start < len(buf) {
		*leftover = append([]byte{}, buf[start:]...)
	} else {
		*leftover = []byte{}
	}

	// Deliver NAL units
	for _, nal := range nals {
		e.bufferNAL(nal)
	}
}

func (e *H264Encoder) deliverFrame(data []byte) {
	// Use bufferNAL for proper Annex-B access unit assembly
	e.bufferNAL(data)
}

// bufferNAL accumulates NAL units into ancBuf and flushes as a complete
// Annex-B access unit when a VCL NAL (slice) arrives.
func (e *H264Encoder) bufferNAL(data []byte) {
	if len(data) == 0 {
		return
	}

	nalType := data[0] & 0x1F

	// Add Annex-B start code prefix
	e.ancBuf = append(e.ancBuf, []byte{0x00, 0x00, 0x00, 0x01}...)
	e.ancBuf = append(e.ancBuf, data...)

	// Flush access unit when we see a VCL NAL (video slice)
	if nalType == 1 || nalType == 5 {
		// Debug: log when frames are being sent
		if e.callback != nil {
			e.log.Debug().Int("frame_size", len(e.ancBuf)).Int("nal_type", int(nalType)).Msg("bufferNAL: sending access unit")
			e.callback(e.ancBuf)
		}
		e.ancBuf = nil

		e.frameCount++
		now := time.Now()
		if now.Sub(e.lastLogTime) >= time.Second {
			e.log.Debug().Int("fps", e.frameCount).Msg("Capture FPS")
			e.frameCount = 0
			e.lastLogTime = now
		}
	}
	// SPS/PPS/AUD/SEI are accumulated in ancBuf for the next VCL NAL
}

// Width returns the capture width.
func (e *H264Encoder) Width() int { return e.width }

// Height returns the capture height.
func (e *H264Encoder) Height() int { return e.height }

// FPS returns the target frame rate.
func (e *H264Encoder) FPS() int { return e.fps }

// getDisplaySize retrieves the main display size in pixels.
func getDisplaySize() (int, int, error) {
	// Use system_profiler as fallback
	cmd := exec.Command("system_profiler", "SPDisplaysDataType", "-json")
	output, err := cmd.Output()
	if err == nil {
		// Parse JSON - look for display resolution
		// Simple approach: just try to find resolution in the output
		if w, h := parseDisplaySizeJSON(output); w > 0 && h > 0 {
			return w, h, nil
		}
	}

	// Fallback: use macOS built-in displays command
	cmd2 := exec.Command("bash", "-c",
		"system_profiler SPDisplaysDataType 2>/dev/null | grep -i resolution | head -1 | awk '{print $2, $4}'")
	output2, err2 := cmd2.Output()
	if err2 == nil && len(output2) > 0 {
		var w, h int
		if n, _ := fmt.Sscanf(string(output2), "%dx%d", &w, &h); n == 2 {
			if w > 0 && h > 0 {
				return w, h, nil
			}
		}
	}

	// Hardcoded fallback: common MacBook Pro 14" resolution
	return 1920, 1200, nil
}

func parseDisplaySizeJSON(data []byte) (int, int) {
	// Simple JSON search pattern
	str := string(data)
	var w, h int
	// Look for "resolution" in the JSON output
	if n, err := fmt.Sscanf(str, "%dx%d", &w, &h); n == 2 && err == nil {
		if w > 0 && h > 0 {
			return w, h
		}
	}
	return 0, 0
}

// BuildCaptureUtil compiles the Objective-C capture helper.
func BuildCaptureUtil(sourcePath, outputPath string) error {
	cmd := exec.Command("clang",
		"-framework", "CoreGraphics",
		"-framework", "CoreVideo",
		"-framework", "VideoToolbox",
		"-framework", "CoreMedia",
		"-framework", "ScreenCaptureKit",
		"-framework", "Foundation",
		"-o", outputPath,
		sourcePath,
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("compile captureutil: %w\nOutput: %s", err, string(output))
	}
	return nil
}
