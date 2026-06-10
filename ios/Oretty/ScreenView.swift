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

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        onTouchDetected?()
        guard let ws = webrtcService else { return }

        let touchCount = gesture.numberOfTouches
        let location = gesture.location(in: gesture.view)
        let translation = gesture.translation(in: gesture.view)

        let screenSize = UIScreen.main.bounds.size
        let scaleX = remoteResolution.width / screenSize.width
        let scaleY = remoteResolution.height / screenSize.height

        // FIX: When zoomed in (> 1.0), 2-finger drag = viewport pan, not scroll
        let isZoomed = zoomLevel > 1.01

        if isZoomed && touchCount == 2 {
            // Viewport panning mode
            switch gesture.state {
            case .changed:
                let delta = CGSize(
                    width: translation.x,
                    height: translation.y
                )
                gesture.setTranslation(.zero, in: gesture.view)
                onPanChange?(delta)
            default:
                break
            }
            return
        }

        switch inputMode {
        case .directTouch:
            handleDirectTouchPan(gesture, ws: ws, touchCount: touchCount,
                                 location: location, translation: translation,
                                 scaleX: scaleX, scaleY: scaleY)
        case .mousePointer:
            handleMousePointerPan(gesture, ws: ws, touchCount: touchCount,
                                  location: location, translation: translation,
                                  scaleX: scaleX, scaleY: scaleY)
        }
    }

    func handleDirectTouchPan(_ gesture: UIPanGestureRecognizer, ws: WebRTCService,
                              touchCount: Int, location: CGPoint,
                              translation: CGPoint, scaleX: CGFloat, scaleY: CGFloat) {
        switch gesture.state {
        case .began:
            if touchCount == 1 {
                // 1-finger drag → left-click drag
                isDragging = true
                ws.sendMouseDown(button: 0,
                                 x: location.x * scaleX,
                                 y: location.y * scaleY)
            } else if touchCount == 2 {
                // 2-finger drag → scroll
                lastPanTranslation = translation
            }
            // 3+ fingers: do nothing (pas geç)

        case .changed:
            if touchCount == 1 && isDragging {
                ws.sendMouseMove(x: location.x * scaleX,
                                 y: location.y * scaleY)
            } else if touchCount == 2 {
                // Compute scroll delta from translation change
                let deltaX = translation.x - lastPanTranslation.x
                let deltaY = translation.y - lastPanTranslation.y
                lastPanTranslation = translation
                ws.sendScroll(deltaX: -deltaX * scaleX,
                              deltaY: -deltaY * scaleY)
            }

        case .ended, .cancelled:
            if touchCount <= 1 && isDragging {
                ws.sendMouseUp(button: 0,
                               x: location.x * scaleX,
                               y: location.y * scaleY)
                isDragging = false
            }
            lastPanTranslation = .zero

        default:
            break
        }
    }

    func handleMousePointerPan(_ gesture: UIPanGestureRecognizer, ws: WebRTCService,
                               touchCount: Int, location: CGPoint,
                               translation: CGPoint, scaleX: CGFloat, scaleY: CGFloat) {
        switch gesture.state {
        case .began:
            if touchCount == 1 {
                // If drag is locked (double-tap-hold), keep mouse down
                if isDragLocked {
                    ws.sendMouseDown(button: 0,
                                     x: cursorPosition.x,
                                     y: cursorPosition.y)
                }
                isDragging = true
                lastVelocityBasedPos = cursorPosition
            } else if touchCount == 2 {
                lastPanTranslation = translation
            }

        case .changed:
            if touchCount == 1 {
                // FIX: Use velocity for smooth cursor movement (RDP-style)
                let velocity = gesture.velocity(in: gesture.view)
                let velocityScale: CGFloat = 0.04 // sensitivity factor (increased for smooth feel)
                let delta = CGPoint(
                    x: velocity.x * velocityScale,
                    y: velocity.y * velocityScale
                )
                // Clamp delta to prevent huge jumps
                let maxDelta: CGFloat = 60
                let clampedDelta = CGPoint(
                    x: max(-maxDelta, min(maxDelta, delta.x)),
                    y: max(-maxDelta, min(maxDelta, delta.y))
                )
                var newPos = CGPoint(
                    x: lastVelocityBasedPos.x + clampedDelta.x,
                    y: lastVelocityBasedPos.y + clampedDelta.y
                )
                newPos.x = max(0, min(remoteResolution.width, newPos.x))
                newPos.y = max(0, min(remoteResolution.height, newPos.y))
                lastVelocityBasedPos = newPos
                cursorPosition = newPos
                onCursorUpdate?(newPos)
                ws.sendMouseMove(x: newPos.x, y: newPos.y)
                gesture.setTranslation(.zero, in: gesture.view)
            } else if touchCount == 2 {
                // 2-finger drag → scroll
                let deltaX = translation.x - lastPanTranslation.x
                let deltaY = translation.y - lastPanTranslation.y
                lastPanTranslation = translation
                ws.sendScroll(deltaX: -deltaX * scaleX,
                              deltaY: -deltaY * scaleY)
                gesture.setTranslation(.zero, in: gesture.view)
            }

        case .ended, .cancelled:
            if touchCount <= 1 && isDragging {
                // Release mouse if drag-locked
                if isDragLocked {
                    ws.sendMouseUp(button: 0,
                                   x: cursorPosition.x,
                                   y: cursorPosition.y)
                    isDragLocked = false
                    onDragLockChange?(false)
                }
                isDragging = false
            }
            lastPanTranslation = .zero

        default:
            break
        }
    }

    // MARK: - Tap Handlers

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        onTouchDetected?()
        guard let ws = webrtcService else { return }

        let location = gesture.location(in: gesture.view)
        let screenSize = UIScreen.main.bounds.size

        switch inputMode {
        case .directTouch:
            // 1-finger tap → left click at touch location
            let scaleX = remoteResolution.width / screenSize.width
            let scaleY = remoteResolution.height / screenSize.height
            ws.sendMouseClick(button: 0,
                              x: location.x * scaleX,
                              y: location.y * scaleY)

        case .mousePointer:
            // FIX: RDP-style double-tap-hold for drag lock
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTapTime < 0.35 {
                // Double-tap → toggle drag lock
                isDragLocked.toggle()
                if isDragLocked {
                    ws.sendMouseDown(button: 0,
                                     x: cursorPosition.x,
                                     y: cursorPosition.y)
                } else {
                    ws.sendMouseUp(button: 0,
                                   x: cursorPosition.x,
                                   y: cursorPosition.y)
                }
                onDragLockChange?(isDragLocked)
                lastTapTime = 0
            } else {
                lastTapTime = now
                if !isDragLocked {
                    // Single tap → left click at cursor
                    ws.sendMouseClick(button: 0,
                                      x: cursorPosition.x,
                                      y: cursorPosition.y)
                }
            }
        }
    }

    @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        onTouchDetected?()
        guard let ws = webrtcService else { return }

        switch inputMode {
        case .mousePointer:
            // 2-finger tap → right click at cursor position
            ws.sendMouseClick(button: 1,
                              x: cursorPosition.x,
                              y: cursorPosition.y)
        case .directTouch:
            // In direct touch mode, 2-finger tap does nothing special
            break
        }
    }

    // MARK: - Long Press Handler

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        onTouchDetected?()
        guard let ws = webrtcService else { return }

        if gesture.state == .began {
            let location = gesture.location(in: gesture.view)
            let screenSize = UIScreen.main.bounds.size

            switch inputMode {
            case .directTouch:
                // Tap&hold → right click at press location
                let scaleX = remoteResolution.width / screenSize.width
                let scaleY = remoteResolution.height / screenSize.height
                ws.sendMouseClick(button: 1,
                                  x: location.x * scaleX,
                                  y: location.y * scaleY)

            case .mousePointer:
                // In mouse pointer mode, long press could begin a drag
                // For now: left click at cursor (simple behavior)
                ws.sendMouseClick(button: 0,
                                  x: cursorPosition.x,
                                  y: cursorPosition.y)
            }
        }
    }

    // MARK: - Pinch Handler

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        onTouchDetected?()

        if gesture.state == .changed {
            let newZoom = zoomLevel * gesture.scale
            let clampedZoom = max(0.5, min(4.0, newZoom))
            onZoomChange?(clampedZoom)
            gesture.scale = 1.0
        }
    }

}

// MARK: - Connection Bar (RDP-style)

// FIX: New connection bar view — semi-transparent, auto-hide, draggable
struct ConnectionBarView: View {
    @Binding var zoomLevel: CGFloat
    @Binding var inputMode: InputMode
    @Binding var showKeyboard: Bool
    let isConnected: Bool
    let onDisconnect: () -> Void

    @State private var barOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            // Zoom controls
            Button(action: { zoomLevel = max(0.5, zoomLevel - 0.25) }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .frame(width: 32, height: 32)

            Text("\(Int(zoomLevel * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40)

            Button(action: { zoomLevel = min(4.0, zoomLevel + 0.25) }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .frame(width: 32, height: 32)

            Divider().frame(height: 24)

            // Mouse mode toggle
            Button(action: {
                inputMode = (inputMode == .directTouch) ? .mousePointer : .directTouch
            }) {
                HStack(spacing: 4) {
                    Image(systemName: inputMode == .directTouch
                          ? "hand.point.up.fill"
                          : "cursorarrow")
                        .font(.system(size: 12))
                    Text(inputMode.rawValue)
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(inputMode == .mousePointer
                            ? Color.blue.opacity(0.3)
                            : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 24)

            // Keyboard toggle
            Button(action: { showKeyboard.toggle() }) {
                Image(systemName: showKeyboard ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .frame(width: 32, height: 32)

            Spacer()

            // Disconnect button
            if isConnected {
                Button(action: onDisconnect) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal, 8)
        .padding(.top, safeAreaTopInset())
        .offset(y: barOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    barOffset = max(-100, min(100, value.translation.height))
                }
                .onEnded { value in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        barOffset = 0
                    }
                }
        )
    }

    private func safeAreaTopInset() -> CGFloat {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            return window.safeAreaInsets.top
        }
        return 44
    }
}

// MARK: - Cursor Indicator (Mouse Pointer Mode)

// FIX: New cursor indicator for mouse pointer mode — shows drag lock state
struct CursorIndicator: View {
    let position: CGPoint
    var isDragLocked: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let remoteRes = CGSize(width: 1920, height: 1200) // default
            let viewX = (position.x / remoteRes.width) * screenSize.width
            let viewY = (position.y / remoteRes.height) * screenSize.height

            ZStack {
                // Outer ring
                Circle()
                    .stroke(isDragLocked ? Color.orange : Color.white.opacity(0.8), lineWidth: isDragLocked ? 3 : 2)
                    .frame(width: isDragLocked ? 24 : 20, height: isDragLocked ? 24 : 20)
                // Inner dot
                Circle()
                    .fill(isDragLocked ? Color.orange : Color.white.opacity(0.6))
                    .frame(width: isDragLocked ? 8 : 4, height: isDragLocked ? 8 : 4)
                // Lock indicator
                if isDragLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.orange)
                        .offset(x: 10, y: -10)
                }
            }
            .position(x: viewX, y: viewY)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @Binding var zoomLevel: CGFloat
    @Binding var showKeyboard: Bool
    @Binding var isScreenStreaming: Bool
    // FIX: Modifier toggle states
    @Binding var modifierStates: [String: Bool]
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ToolbarButton(systemName: "chevron.left") {
                state.activeView = .hosts
            }
            Divider().frame(height: 28)

            // FIX: Modifier toggle buttons with visual state
            ModifierToggleButton(title: "\u{2318}", isActive: modifierStates["cmd"] ?? false) {
                toggleModifier("cmd")
            }
            ModifierToggleButton(title: "\u{2325}", isActive: modifierStates["alt"] ?? false) {
                toggleModifier("alt")
            }
            ModifierToggleButton(title: "\u{2303}", isActive: modifierStates["ctrl"] ?? false) {
                toggleModifier("ctrl")
            }
            ModifierToggleButton(title: "\u{21E7}", isActive: modifierStates["shift"] ?? false) {
                toggleModifier("shift")
            }

            Divider().frame(height: 28)

            ToolbarButton(systemName: "minus.magnifyingglass") {
                zoomLevel = max(0.5, zoomLevel - 0.25)
            }
            Text("\\(Int(zoomLevel * 100))%")
                .font(.caption)
                .frame(width: 40)
            ToolbarButton(systemName: "plus.magnifyingglass") {
                zoomLevel = min(4.0, zoomLevel + 0.25)
            }

            Divider().frame(height: 28)

            // FIX: Enter (return) in toolbar — native keyboard Enter unreliable
            ToolbarButton(title: "\u{21B5}") {
                state.webrtc.sendKeyEvent(key: "return", down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak state = self.state] in
                    state?.webrtc.sendKeyEvent(key: "return", down: false)
                }
            }

            // FIX: Tab in toolbar
            ToolbarButton(title: "\u{21E5}") {
                state.webrtc.sendKeyEvent(key: "tab", down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak state = self.state] in
                    state?.webrtc.sendKeyEvent(key: "tab", down: false)
                }
            }

            // FIX: Backspace in toolbar
            ToolbarButton(title: "\u{232B}") {
                state.webrtc.sendKeyEvent(key: "backspace", down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak state = self.state] in
                    state?.webrtc.sendKeyEvent(key: "backspace", down: false)
                }
            }

            Spacer()

            ToolbarButton(systemName: isScreenStreaming ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle") {
                isScreenStreaming.toggle()
                if isScreenStreaming {
                    state.webrtc.sendScreenStart()
                } else {
                    state.webrtc.sendScreenStop()
                }
            }

            ToolbarButton(systemName: showKeyboard ? "keyboard.fill" : "keyboard") {
                showKeyboard.toggle()
            }

            // FIX: Replaced empty fullscreen button with cut/copy/paste
            ToolbarButton(systemName: "scissors") {
                sendPasteCommand("x")
            }
            ToolbarButton(systemName: "doc.on.doc") {
                sendPasteCommand("c")
            }
            ToolbarButton(systemName: "doc.on.clipboard") {
                sendPasteCommand("v")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // FIX: Send cut/copy/paste with cancellable timers (via parent)
    private func sendPasteCommand(_ keyChar: String) {
        state.webrtc.sendKeyEvent(key: keyChar, modifiers: ["cmd"], down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak state = self.state] in
            state?.webrtc.sendKeyEvent(key: keyChar, modifiers: ["cmd"], down: false)
        }
    }

    // FIX: Modifier toggle with persistent state
    private func toggleModifier(_ modifier: String) {
        let isActive = modifierStates[modifier] ?? false
        modifierStates[modifier] = !isActive
        state.webrtc.sendKeyEvent(key: modifier, modifiers: [], down: !isActive)
    }
}

struct ToolbarButton: View {
    var title: String?
    var systemName: String?
    var action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(systemName: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let title = title {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
            } else if let systemName = systemName {
                Image(systemName: systemName)
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}

// FIX: New toggle button for modifier keys with active state highlighting
struct ModifierToggleButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: isActive ? .bold : .medium))
                .frame(width: 36, height: 36)
                .background(isActive ? Color.blue.opacity(0.3) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
    }
}

// MARK: - Hidden Text Field (iOS Native Keyboard)

struct HiddenTextField: UIViewRepresentable {
    @Binding var showKeyboard: Bool
    var onKeyPress: (String, [String]) -> Void
    @Binding var modifierStates: [String: Bool]

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if showKeyboard {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyPress: onKeyPress, modifierStates: $modifierStates)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var onKeyPress: (String, [String]) -> Void
        var modifierStates: Binding<[String: Bool]>

        init(onKeyPress: @escaping (String, [String]) -> Void, modifierStates: Binding<[String: Bool]>) {
            self.onKeyPress = onKeyPress
            self.modifierStates = modifierStates
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let modifiers = getActiveModifiers()

            if string.isEmpty {
                // Backspace
                onKeyPress("backspace", modifiers)
            } else if string == "\n" {
                onKeyPress("return", modifiers)
            } else {
                for char in string {
                    onKeyPress(String(char), modifiers)
                }
            }

            // Clear text field so it doesn't accumulate text
            DispatchQueue.main.async {
                textField.text = ""
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onKeyPress("return", getActiveModifiers())
            textField.resignFirstResponder()
            return false
        }

        func getActiveModifiers() -> [String] {
            return modifierStates.wrappedValue.filter { $0.value }.map { $0.key }
        }
    }
}

// MARK: - Keyboard Accessory View (compact, ~120px)

struct KeyboardAccessoryView: View {
    @Binding var modifierStates: [String: Bool]
    var onKeyPress: (String, [String]) -> Void
    var onModifierToggle: (String) -> Void

    let modifierKeys = ["cmd", "alt", "ctrl", "shift", "caps", "fn"]
    let modifierDisplay: [String: String] = [
        "cmd": "\u{2318}", "alt": "\u{2325}", "ctrl": "\u{2303}", "shift": "\u{21E7}", "caps": "Caps", "fn": "Fn"
    ]

    let specialKeys: [(key: String, display: String)] = [
        ("esc", "\u{238B} Esc"), ("tab", "\u{21E5} Tab"), ("backspace", "\u{232B} Del"), ("delete", "\u{2326} FwdDel"),
        ("return", "\u{21A9} Enter"), ("up", "\u{2191}"), ("down", "\u{2193}"), ("left", "\u{2190}"), ("right", "\u{2192}"),
        ("home", "\u{2196} Home"), ("end", "\u{2198} End"), ("pgup", "\u{21DE} PgUp"), ("pgdn", "\u{21DF} PgDn"), ("insert", "Ins")
    ]

    let fKeys: [(key: String, display: String)] = (1...12).map { ("f\($0)", "F\($0)") }

    var body: some View {
        VStack(spacing: 4) {
            // Row 1: Modifier Toggle Chips
            HStack(spacing: 6) {
                ForEach(modifierKeys, id: \.self) { key in
                    ModifierChip(
                        title: modifierDisplay[key] ?? key,
                        isActive: modifierStates[key] ?? false
                    ) {
                        onModifierToggle(key)
                    }
                }
            }
            .padding(.horizontal, 8)

            // Row 2: Navigation + Special Keys (scrollable horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(specialKeys, id: \.key) { item in
                        AccessoryKeyButton(title: item.display) {
                            onKeyPress(item.key, [])
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Row 3: F-Key Row (scrollable horizontal, smaller font)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(fKeys, id: \.0) { (key, display) in
                        AccessoryKeyButton(title: display, fontSize: 11) {
                            onKeyPress(key, [])
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Modifier Chip (pill-style toggle button)

struct ModifierChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.blue : Color(.systemGray5))
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Accessory Key Button (compact key in scrollable row)

struct AccessoryKeyButton: View {
    let title: String
    var fontSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray5))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ScreenView()
        .environmentObject(AppState())
}
