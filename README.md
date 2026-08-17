# Oretty — Remote Mac Control from iOS

Oretty lets you **control your Mac from an iPhone/iPad** with ultra-low latency screen sharing (H.264 hardware encoding), full terminal access, and clipboard sync.

> **Status:** MVP Phase — Core signaling + WebRTC works. iOS app scaffolding ready.

## Architecture

```
iPhone (SwiftUI + WebRTC)  ← WebRTC (DTLS-SRTP) →  Mac (orettyd Go daemon)
                                   ↕
                          Alex (Signaling + TURN)
```

- **Mac (Ares/Host):** `orettyd` Go daemon + ScreenCaptureKit/VideoToolbox H.264 → macOS menubar
- **iPhone (Client):** SwiftUI app with WebRTC native video render + terminal + toolbar
- **Alex (Cloud):** Signaling server (Go, WSS TLS, port 443) + TURN (coturn, port 3478)

## Quick Start

### Prerequisites
- macOS 15+ (for ScreenCaptureKit)
- Xcode 26+ (for iOS app)
- Go 1.22+

### Build

```bash
# Build daemon + capture utility
make build

# Build iOS app
make ios
# Then open ios/Oretty.xcodeproj in Xcode
```

### Run

```bash
# Start the daemon (connects to signaling server on Alex)
make run-host

# Or specify a custom signaling server
SIGNAL_URL=wss://your-server:443 make run-host
```

### iOS App

1. `make ios` → generates Xcode project
2. Open `ios/Oretty.xcodeproj` in Xcode
3. Select iOS 26 simulator (or real device)
4. Build & Run
5. Enter pairing code from Mac menubar

## Project Structure

```
oretty/
├── cmd/
│   ├── orettyd/          # Go daemon (Mac host)
│   │   ├── main.go       # Entry point + session management
│   │   └── control_darwin.go  # Mouse/keyboard CGEvent bridge
│   └── captureutil/      # ObjC screen capture + H.264 encoder
│       └── main.m
├── internal/
│   ├── screen/           # Screen capture (captureutil subprocess)
│   ├── pty/              # Terminal PTY
│   ├── clipboard/        # Clipboard sync
│   ├── webrtc/           # WebRTC engine (pion/webrtc)
│   ├── signaling/        # Signaling client
│   └── protocol/         # Message types
├── ios/                  # iOS app (SwiftUI)
│   ├── Oretty/           # Source files
│   │   ├── App.swift
│   │   ├── ConnectView.swift
│   │   ├── HostListView.swift
│   │   ├── ScreenView.swift   # WebRTC video + touch input
│   │   ├── TerminalView.swift
│   │   └── SettingsView.swift
│   └── project.yml       # XcodeGen spec
├── server/               # Alex cloud deployment
│   ├── signaling/        # Go signaling server
│   ├── turn/             # coturn config
│   └── docker-compose.yml
├── macos/                # macOS menubar app (TBD)
├── bin/                  # Build artifacts
├── Makefile
└── README.md
```

## Protocol

### Signaling (WebSocket → WSS)
| Direction | Message | Description |
|-----------|---------|-------------|
| Client→Server | `register` | `{device_id, is_host, name?, platform?}` |
| Server→Client | `registered` | `{client_id, is_host}` |
| Host→Server | `create_room` | `{room_name?}` |
| Server→Host | `room_created` | `{room_id, room_name}` |
| Client→Server | `join_room` | `{room_id}` |
| Peer→Server | `signal` | `{target_id, data:{type, sdp/candidate}}` |
| Server→Peer | `signal` | `{sender_id, data:{type, sdp/candidate}}` |

### Data Channels (WebRTC)
| Channel | Direction | Purpose |
|---------|-----------|---------|
| `auth` | Bidirectional | Pairing/auth |
| `terminal` | Bidirectional | PTY I/O |
| `screen` | Mac→Client | Screen start/stop commands |
| `control` | Client→Mac | Mouse, keyboard, unlock events |
| `clipboard` | Bidirectional | Clipboard sync |

### Video Track
- Codec: H.264 (Main profile)
- Transport: WebRTC RTP video track (NOT data channel)
- Source: ScreenCaptureKit + VideoToolbox HW encoding
- Quality: Adaptive (3-10 Mbps depending on resolution)

## Security

- **Transport:** DTLS-SRTP (E2E encrypted WebRTC)
- **Signaling:** WSS (TLS 1.3)
- **Auth:** 8-digit pairing code + device whitelist
- **TURN:** Auth token + DTLS passthrough (server cannot decrypt)
- **Lock Screen:** Viewable + terminal accessible. Unlock via SMJobBless helper (planned).

## Deployment (Alex)

Signaling + TURN are deployed on Oracle Cloud ARM instance:

```bash
# Signaling: WSS :443
curl -k https://161.118.185.63:443/health

# Hosts API:
curl -k https://161.118.185.63:443/api/hosts

# TURN: STUN/TURN on :3478
# User: oretty
```

## Roadmap

- ✅ Signaling server (Go, TLS, SQLite)
- ✅ WebRTC engine (pion, H.264 video track)
- ✅ Screen capture (ScreenCaptureKit + VideoToolbox)
- ✅ iOS app scaffolding (SwiftUI, WebRTC framework)
- ✅ Terminal PTY
- ✅ Clipboard sync
- 🔄 macOS Menubar app (Swift)
- 🔄 Privileged Helper Tool (lock screen unlock)
- 🔄 H.265/HEVC support
- 🔄 iOS App Store release
- 🔄 Android port

## License

MIT © Samet Yılmaztemel
