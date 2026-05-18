.PHONY: build clean test ios run-signal run-host help

NAME    := orettyd
VERSION := 1.0.0
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

LDFLAGS := -ldflags "-X main.Version=$(VERSION) -X main.Commit=$(COMMIT)"

# ─── Build ───────────────────────────────────────
build: bin/$(NAME) bin/captureutil

bin/$(NAME):
	go build $(LDFLAGS) -o bin/$(NAME) ./cmd/orettyd/

bin/captureutil:
	clang -framework CoreGraphics -framework CoreVideo \
		-framework VideoToolbox -framework CoreMedia \
		-framework ScreenCaptureKit -framework Foundation \
		-o bin/captureutil cmd/captureutil/main.m

ios:
	cd ios && xcodegen generate && open Oretty.xcodeproj

macos:
	cd macos && xcodegen generate 2>/dev/null || true

# ─── Test ────────────────────────────────────────
test:
	go test ./... -v -count=1

test-short:
	go test ./... -short

# ─── Run ─────────────────────────────────────────
SIGNAL_URL ?= wss://161.118.185.63:443

run-signal:
	./bin/orettyd -signal "$(SIGNAL_URL)"

run-host:
	./bin/orettyd -signal "$(SIGNAL_URL)"

dev:
	@echo "Starting orettyd in dev mode..."
	@./bin/orettyd -signal "$(SIGNAL_URL)" -name "Ares-Dev"

# ─── Clean ──────────────────────────────────────
clean:
	rm -rf bin/
	go clean

# ─── Lint ────────────────────────────────────────
lint:
	golangci-lint run ./...

# ─── Help ────────────────────────────────────────
help:
	@echo "Oretty v$(VERSION)"
	@echo ""
	@echo "Targets:"
	@echo "  build       Build orettyd + captureutil"
	@echo "  ios         Generate iOS Xcode project"
	@echo "  test        Run all tests"
	@echo "  run-signal  Run with signaling server (URL via SIGNAL_URL)"
	@echo "  run-host    Run as host (alias for run-signal)"
	@echo "  dev         Run in dev mode"
	@echo "  clean       Clean build artifacts"
	@echo ""
	@echo "Config:"
	@echo "  SIGNAL_URL  Signaling server URL (default: wss://161.118.185.63:443)"
