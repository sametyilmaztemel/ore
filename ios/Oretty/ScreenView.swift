import SwiftUI
import WebRTC

// FIX: Input mode for gesture handling (RDP-style)
enum InputMode: String, CaseIterable {
    case directTouch = "Direct Touch"
    case mousePointer = "Mouse Pointer"
}

struct ScreenView: View {
    @EnvironmentObject var state: AppState
    @State private var zoomLevel: CGFloat = 1.0
    @State private var showToolbar = true
    @State private var showKeyboard = false
    @State private var lastMouseLocation: CGPoint = .zero
    @State private var isScreenStreaming = false
    // FIX: Dynamic resolution (default MacBook Pro 14" 1920x1200)
    @State private var remoteResolution = CGSize(width: 1920, height: 1200)
    // FIX: Drag tracking state
    @State private var isDragging = false
    // FIX: Scroll tracking state
    @State private var lastScrollTranslation: CGSize = .zero
    // FIX: Modifier toggle states for toolbar
    @State private var modifierStates: [String: Bool] = [:]
    // FIX: Key-up timers to prevent stacking of key events
    @State private var keyUpTimers: [String: DispatchWorkItem] = [:]
    // FIX: Input mode (Direct Touch / Mouse Pointer)
    @State private var inputMode: InputMode = .directTouch
    // FIX: RDP-style drag lock state for cursor indicator
    @State private var isDragLocked = false
    // FIX: Connection bar auto-hide
    @State private var showConnectionBar = true
    @State private var connectionBarHideTask: DispatchWorkItem? = nil
    // FIX: Mouse pointer cursor position
    @State private var cursorPosition: CGPoint = .zero
    // FIX: Viewport offset for zoom panning
    @State private var viewOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // Main content VStack
            VStack(spacing: 0) {
                ZStack {
                    Color.black

                    if state.webrtc.isConnected {
                        ZStack {
                            GestureEnabledVideoView(
                                webrtcService: state.webrtc,
                                remoteResolution: remoteResolution,
                                inputMode: inputMode,
                                zoomLevel: zoomLevel,
                                cursorPosition: cursorPosition,
                                onZoomChange: { newZoom in
                                        zoomLevel = newZoom
                                        // Reset view offset when zoom returns to 1.0
                                        if newZoom <= 1.0 {
                                            viewOffset = .zero
                                        }
                                    },
                                    onTouchDetected: { showConnectionBarTemporarily() },
                                    onCursorUpdate: { newPos in
                                        cursorPosition = newPos
                                    },
                                    onDragLockChange: { locked in
                                        isDragLocked = locked
                                    },
                                    onPanChange: { delta in
                                        viewOffset = CGSize(
                                            width: viewOffset.width + delta.width,
                                            height: viewOffset.height + delta.height
                                        )
                                    }
                            )
                            .scaleEffect(zoomLevel)
                            .offset(viewOffset)

                            // FIX: Show "Waiting for video stream" overlay when connected but track not yet received
                            if state.webrtc.remoteVideoTrack == nil {
                                VStack(spacing: 16) {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                        .tint(.white)
                                    Text("Waiting for screen stream...")
                                        .foregroundColor(.white)
                                        .font(.headline)
                                    Text("Connected, establishing video channel")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.black.opacity(0.85))
                                .transition(.opacity)
                            }

                        // FIX: Cursor indicator for mouse pointer mode
                        if inputMode == .mousePointer {
                            CursorIndicator(position: cursorPosition, isDragLocked: isDragLocked)
                        }
                        }
                    } else {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Connecting to \(state.connectedHost ?? "Mac")...")
                                .foregroundColor(.white)

                            switch state.connectionPhase {
                            case .negotiating:
                                Text("Establishing WebRTC connection")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            case .connected:
                                Text("Starting screen stream...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            case .failed(let error):
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            default:
                                Text("Please wait...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Toolbar
                if showToolbar {
                    ToolbarView(
                        zoomLevel: $zoomLevel,
                        showKeyboard: $showKeyboard,
                        isScreenStreaming: $isScreenStreaming,
                        modifierStates: $modifierStates
                    )
                }

                // Hidden text field for iOS native keyboard input
                HiddenTextField(
                    showKeyboard: $showKeyboard,
                    onKeyPress: { key, modifiers in
                        sendKey(key: key, modifiers: modifiers)
                    },
                    modifierStates: $modifierStates
                )
                .frame(height: 0)
                .opacity(0)

                // Compact keyboard accessory bar (modifier toggles + special keys + F-keys)
                if showKeyboard {
                    KeyboardAccessoryView(
                        modifierStates: $modifierStates,
                        onKeyPress: { key, modifiers in
                            sendKey(key: key, modifiers: modifiers)
                        },
                        onModifierToggle: { modifier in
                            let isActive = modifierStates[modifier] ?? false
                            modifierStates[modifier] = !isActive
                            state.webrtc.sendKeyEvent(key: modifier, modifiers: [], down: !isActive)
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }

            // FIX: Connection bar overlay (top)
            VStack {
                ConnectionBarView(
                    zoomLevel: $zoomLevel,
                    inputMode: $inputMode,
                    showKeyboard: $showKeyboard,
                    isConnected: state.webrtc.isConnected,
                    onDisconnect: {
                        state.activeView = .hosts
                    }
                )
                .opacity(showConnectionBar ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: showConnectionBar)

                Spacer()
            }
        }
        .onDisappear(perform: stopScreenStream)
        .onAppear {
            state.webrtc.attachRendererIfNeeded()
        }
        .edgesIgnoringSafeArea(.all)
        .statusBar(hidden: true)
    }

    private func stopScreenStream() {
        state.webrtc.sendScreenStop()
        isScreenStreaming = false
    }

    // FIX: Send key with cancellable up timer to prevent stacking
    private func sendKey(key: String, modifiers: [String]) {
        state.webrtc.sendKeyEvent(key: key, modifiers: modifiers, down: true)

        // Cancel any pending up event for this key
        keyUpTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak state = self.state] in
            state?.webrtc.sendKeyEvent(key: key, modifiers: modifiers, down: false)
        }
        keyUpTimers[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    // FIX: Show connection bar temporarily (auto-hide after 5 seconds)
    private func showConnectionBarTemporarily() {
        showConnectionBar = true
        connectionBarHideTask?.cancel()
        let task = DispatchWorkItem {
            DispatchQueue.main.async {
                self.showConnectionBar = false
            }
        }
        connectionBarHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: task)
    }
}

// MARK: - Gesture-Enabled Video Container (UIKit Gesture Recognizers)

// FIX: Replaced SwiftUI gesture modifiers with UIKit gesture recognizers for reliable touch tracking
struct GestureEnabledVideoView: UIViewRepresentable {
    let webrtcService: WebRTCService
    var remoteResolution: CGSize
    var inputMode: InputMode
    var zoomLevel: CGFloat
    var cursorPosition: CGPoint

    var onZoomChange: ((CGFloat) -> Void)?
    var onTouchDetected: (() -> Void)?
    var onCursorUpdate: ((CGPoint) -> Void)?
    var onDragLockChange: ((Bool) -> Void)?
    var onPanChange: ((CGSize) -> Void)?

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.isMultipleTouchEnabled = true

        // Video rendering view
        let videoView = RTCMTLVideoView()
        videoView.videoContentMode = .scaleAspectFit
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Setup renderer (use videoView directly)
        webrtcService.videoRenderer = VideoRendererHolder(renderer: videoView)

        // FIX: Setup UIKit gesture recognizers
        context.coordinator.setupGestureRecognizers(on: container)

        return container
    }

    func makeCoordinator() -> GestureCoordinator {
        GestureCoordinator()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.webrtcService = webrtcService
        context.coordinator.remoteResolution = remoteResolution
        context.coordinator.inputMode = inputMode
        context.coordinator.zoomLevel = zoomLevel
        context.coordinator.cursorPosition = cursorPosition

        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.onTouchDetected = onTouchDetected
        context.coordinator.onCursorUpdate = onCursorUpdate
        context.coordinator.onDragLockChange = onDragLockChange
        context.coordinator.onPanChange = onPanChange
    }
}

// FIX: Gesture coordinator with UIKit recognizers for reliable 1/2/3 finger differentiation
@MainActor
class GestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var webrtcService: WebRTCService?
    var remoteResolution: CGSize = .init(width: 1920, height: 1200)
    var inputMode: InputMode = .directTouch
    var zoomLevel: CGFloat = 1.0
    var cursorPosition: CGPoint = .zero

    var onZoomChange: ((CGFloat) -> Void)?
    var onTouchDetected: (() -> Void)?
    var onCursorUpdate: ((CGPoint) -> Void)?
    var onDragLockChange: ((Bool) -> Void)?
    var onPanChange: ((CGSize) -> Void)?

    // Gesture recognizers
    var panGesture: UIPanGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var twoFingerTapGesture: UITapGestureRecognizer!
    var longPressGesture: UILongPressGestureRecognizer!
    var pinchGesture: UIPinchGestureRecognizer!

    // State tracking
    var isDragging = false
    var lastPanTranslation: CGPoint = .zero
    // FIX: RDP-style drag lock (double-tap-hold)
    var isDragLocked = false
    var lastTapTime: TimeInterval = 0
    var isDoubleTapHolding = false
    var dragStartPoint: CGPoint = .zero
    var lastVelocityBasedPos: CGPoint = .zero
    // FIX: Viewport panning state for zoom
    var viewPanOffset: CGSize = .zero

    func setupGestureRecognizers(on view: UIView) {
        // FIX: Pan gesture — handles 1/2/3 finger drag, scroll, cursor move
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 3
        panGesture.delegate = self
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)

        // FIX: Single tap — left click
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.numberOfTapsRequired = 1
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)

        // FIX: Two-finger tap — right click in mouse pointer mode
        twoFingerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTapGesture.numberOfTouchesRequired = 2
        twoFingerTapGesture.numberOfTapsRequired = 1
        twoFingerTapGesture.delegate = self
        view.addGestureRecognizer(twoFingerTapGesture)

        // FIX: Long press — right click in direct touch mode
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.numberOfTouchesRequired = 1
        longPressGesture.delegate = self
        view.addGestureRecognizer(longPressGesture)

        // FIX: Pinch — zoom in/out
        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        view.addGestureRecognizer(pinchGesture)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                          shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pinch + pan to work together (two-finger pinch that also pans)
        if (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
           (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                          shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Tap recognizers should fail if a pan or long press begins
        if gestureRecognizer is UITapGestureRecognizer &&
           (otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer) {
            return true
        }
        return false
    }

    // MARK: - Pan Gesture Handler
