import Foundation
import OSLog
@preconcurrency import WebRTC

// MARK: - WebRTC Service Delegate

protocol WebRTCServiceDelegate: AnyObject {
    func webrtcDidChangeState(_ state: RTCIceConnectionState)
    func webrtcDidReceiveVideoTrack(_ track: RTCVideoTrack)
    func webrtcDidReceiveTerminalData(_ data: Data)
    func webrtcDidReceiveClipboardData(_ text: String)
    func webrtcDidAuthenticate()
    func webrtcDidFail(_ error: Error)
}

// MARK: - VP8-Only Codec Factories

class VP8OnlyVideoDecoderFactory: RTCDefaultVideoDecoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        return [RTCVideoCodecInfo(name: "VP8")]
    }
}

class VP8OnlyVideoEncoderFactory: RTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        return [RTCVideoCodecInfo(name: "VP8")]
    }
}

// MARK: - Video Renderer Holder

class VideoRendererHolder {
    weak var renderer: RTCVideoRenderer?
    init(renderer: RTCVideoRenderer?) {
        self.renderer = renderer
    }
}

// MARK: - WebRTC Service

class WebRTCService: NSObject, @unchecked Sendable {
    weak var delegate: WebRTCServiceDelegate?

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var signalingService: SignalingService
    private var targetID: String = ""

    // Data channels
    private var terminalChannel: RTCDataChannel?
    private var controlChannel: RTCDataChannel?
    private var clipboardChannel: RTCDataChannel?
    private var authChannel: RTCDataChannel?
    private var screenChannel: RTCDataChannel?

    // Host device ID for signaling target
    private var hostID: String = ""

    // Remote video track
    private(set) var remoteVideoTrack: RTCVideoTrack?

    // Video renderer holder (weak ref set by ScreenView)
    var videoRenderer: VideoRendererHolder? {
        didSet {
            // Auto-attach if remoteVideoTrack already arrived before renderer was set
            if let renderer = videoRenderer?.renderer, let track = remoteVideoTrack {
                track.add(renderer)
                os_log("[WebRTC] Renderer auto-attached via didSet, track=%@", track.trackId)
            }
        }
    }

    // ICE servers
    private let stunServer = "stun:stun.l.google.com:19302"
    private let turnServerURL = "turn:161.118.185.63:3478"
    private let turnUsername = "oretty"
    private let turnCredential = "EZ0Er3g4Ir5T0A7vbxYf"

    // Published via MainActor bridge
    private var _isConnected = false
    private var _connectionState: RTCIceConnectionState = .new

    var isConnected: Bool {
        return _isConnected
    }

    var connectionState: RTCIceConnectionState {
        return _connectionState
    }

    private var onStateChange: (@MainActor @Sendable (RTCIceConnectionState, Bool) -> Void)?

    func onConnectionStateChange(_ handler: @escaping (@MainActor @Sendable (RTCIceConnectionState, Bool) -> Void)) {
        onStateChange = handler
    }

    init(signalingService: SignalingService) {
        self.signalingService = signalingService
        super.init()
        setupFactory()
        signalingService.onSignalMessage = { [weak self] senderID, data in
            self?.handleSignalMessage(senderID: senderID, data: data)
        }
    }

    private func setupFactory() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        os_log("[WebRTC] Factory initialized with default codecs (H.264 + VP8)")
    }

    // MARK: - Connection

    func connect(targetID: String) {
        self.targetID = targetID

        let configuration = RTCConfiguration()
        configuration.iceServers = [
            RTCIceServer(urlStrings: [stunServer]),
            RTCIceServer(urlStrings: [turnServerURL],
                        username: turnUsername,
                        credential: turnCredential)
        ]
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        )
    }

    func disconnect() {
        terminalChannel?.close()
        clipboardChannel?.close()
        controlChannel?.close()
        authChannel?.close()
        screenChannel?.close()

        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil

        Task { @MainActor [weak self] in
            self?._isConnected = false
            self?.onStateChange?(.disconnected, false)
        }
    }

    // MARK: - Renderer Attachment

    /// Attaches the video renderer to the remote video track if not already connected.
    /// Call this when the ScreenView appears to handle the case where the
    /// video track arrived before the renderer was created.
    func attachRendererIfNeeded() {
        guard let renderer = videoRenderer?.renderer, let track = remoteVideoTrack else {
            os_log("[WebRTC] attachRendererIfNeeded skipped: renderer=%{public}@, track=%{public}@",
                   videoRenderer?.renderer == nil ? "nil" : "set",
                   remoteVideoTrack == nil ? "nil" : "set")
            return
        }
        track.add(renderer)
        os_log("[WebRTC] Renderer attached to existing video track %@ via attachRendererIfNeeded", track.trackId)
    }

    // MARK: - Signaling Message Handling

    private func handleSignalMessage(senderID: String, data: [String: Any]) {
        guard let type = data["type"] as? String else { return }

        // Store host device ID from the first signal we receive
        if hostID.isEmpty {
            hostID = senderID
        }

        switch type {
        case "offer":
            if let sdp = data["sdp"] as? String {
                handleOffer(sdp: sdp)
            }

        case "ice_candidate":
            if let candidate = data["candidate"] as? String,
               let sdpMid = data["sdpMid"] as? String,
               let sdpMLineIndex = data["sdpMLineIndex"] as? Int32 {
                let iceCandidate = RTCIceCandidate(
                    sdp: candidate,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                peerConnection?.add(iceCandidate)
            }

        default:
            break
        }
    }

    private func handleOffer(sdp: String) {
        let sessionDesc = RTCSessionDescription(type: .offer, sdp: sdp)

        // Safety check: if peerConnection is nil, connect first
        if peerConnection == nil {
            print("[WebRTC] peerConnection nil in handleOffer, connecting to host=\(hostID)")
            connect(targetID: hostID.isEmpty ? targetID : hostID)
            // If still nil after connect, abort
            guard peerConnection != nil else {
                print("[WebRTC] Failed to create peerConnection")
                return
            }
        }

        peerConnection?.setRemoteDescription(sessionDesc) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                Task { @MainActor [weak self] in
                    self?.delegate?.webrtcDidFail(error)
                }
                return
            }

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )
            self.peerConnection?.answer(for: constraints) { [weak self] sdp, error in
                guard let self = self else { return }
                if let error = error {
                    Task { @MainActor [weak self] in
                        self?.delegate?.webrtcDidFail(error)
                    }
                    return
                }
                guard let sdp = sdp else { return }

                self.peerConnection?.setLocalDescription(sdp) { error in
                    if let error = error {
                        Task { @MainActor [weak self] in
                            self?.delegate?.webrtcDidFail(error)
                        }
                        return
                    }
                    let target = self.hostID.isEmpty ? (self.signalingService.roomID ?? "") : self.hostID
                    self.signalingService.sendSignalSDP(
                        targetID: target,
                        type: "answer",
                        sdp: sdp.sdp
                    )
                }
            }
        }
    }

    // MARK: - Data Channels

    private func setupDataChannel(_ dataChannel: RTCDataChannel) {
        let label = dataChannel.label

        switch label {
        case "auth":
            authChannel = dataChannel
            dataChannel.delegate = self
            sendAuthData()

        case "terminal":
            terminalChannel = dataChannel
            dataChannel.delegate = self

        case "control":
            controlChannel = dataChannel
            dataChannel.delegate = self

        case "clipboard":
            clipboardChannel = dataChannel
            dataChannel.delegate = self

        case "screen":
            screenChannel = dataChannel
            dataChannel.delegate = self

        default:
            dataChannel.delegate = self
        }
    }

    private func sendAuthData() {
        let authMsg: [String: Any] = ["type": "auth"]
        if let data = try? JSONSerialization.data(withJSONObject: authMsg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            authChannel?.sendData(buffer)
        }
    }

    // MARK: - Send Commands

    func sendTerminalInput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        terminalChannel?.sendData(buffer)
    }

    func sendMouseMove(x: Double, y: Double) {
        let payload: [String: Any] = ["x": x, "y": y]
        sendControlEvent(type: "mouse_move", payload: payload)
    }

    func sendMouseClick(button: Int = 0, x: Double, y: Double) {
        let payload: [String: Any] = ["x": x, "y": y, "button": button, "down": true]
        sendControlEvent(type: "mouse_click", payload: payload)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let payloadUp: [String: Any] = ["x": x, "y": y, "button": button, "down": false]
            self?.sendControlEvent(type: "mouse_click", payload: payloadUp)
        }
    }

    func sendScroll(deltaX: Double, deltaY: Double) {
        let payload: [String: Any] = ["delta_x": deltaX, "delta_y": deltaY]
        sendControlEvent(type: "mouse_scroll", payload: payload)
    }

    // FIX: Send mouse down event only (for drag support)
    func sendMouseDown(button: Int = 0, x: Double, y: Double) {
        let payload: [String: Any] = ["x": x, "y": y, "button": button, "down": true]
        sendControlEvent(type: "mouse_click", payload: payload)
    }

    // FIX: Send mouse up event only (for drag support)
    func sendMouseUp(button: Int = 0, x: Double, y: Double) {
        let payload: [String: Any] = ["x": x, "y": y, "button": button, "down": false]
        sendControlEvent(type: "mouse_click", payload: payload)
    }

    // FIX: Send mouse mode change event (Direct Touch / Mouse Pointer)
    func sendMouseModeChange(mode: String) {
        let payload: [String: Any] = ["mode": mode]
        sendControlEvent(type: "mouse_mode", payload: payload)
    }

    func sendKeyEvent(key: String, code: String = "", modifiers: [String] = [], down: Bool) {
        let payload: [String: Any] = ["key": key, "code": code, "modifiers": modifiers, "down": down]
        sendControlEvent(type: "key_event", payload: payload)
    }

    func sendScreenStart() {
        let msg: [String: Any] = ["type": "screen_start"]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            screenChannel?.sendData(buffer)
        }
    }

    func sendScreenStop() {
        let msg: [String: Any] = ["type": "screen_stop"]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            screenChannel?.sendData(buffer)
        }
    }

    func sendClipboardText(_ text: String) {
        let msg: [String: Any] = ["type": "clipboard", "payload": ["text": text]]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            clipboardChannel?.sendData(buffer)
        }
    }

    func sendResize(rows: Int, cols: Int) {
        let msg: [String: Any] = ["type": "resize", "payload": ["rows": rows, "cols": cols]]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            terminalChannel?.sendData(buffer)
        }
    }

    private func sendControlEvent(type: String, payload: [String: Any]) {
        var msg: [String: Any] = ["type": type]
        if !payload.isEmpty {
            msg["payload"] = payload
        }
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            controlChannel?.sendData(buffer)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCService: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didChange state: RTCSignalingState) {
        print("[WebRTC] Signaling state: \(state.rawValue)")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didAdd stream: RTCMediaStream) {
        os_log("[WebRTC] Stream added: %@, videoTracks=%d, audioTracks=%d",
               stream.streamId, stream.videoTracks.count, stream.audioTracks.count)

        if let videoTrack = stream.videoTracks.first {
            // Store track reference and add to renderer
            Task { @MainActor in
                self.remoteVideoTrack = videoTrack
                os_log("[WebRTC] remoteVideoTrack set: %@, readyState=%d, source=%{public}@",
                       videoTrack.trackId, videoTrack.readyState.rawValue,
                       videoTrack.source)
                if let renderer = self.videoRenderer?.renderer {
                    videoTrack.add(renderer)
                    os_log("[WebRTC] Renderer attached to video track %@", videoTrack.trackId)
                } else {
                    os_log("[WebRTC] No renderer available yet for track %@", videoTrack.trackId)
                }
                self.delegate?.webrtcDidReceiveVideoTrack(videoTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didRemove stream: RTCMediaStream) {
        os_log("[WebRTC] Stream removed: %@", stream.streamId)
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didChange newState: RTCIceConnectionState) {
        let connected = (newState == .connected || newState == .completed)
        os_log("[WebRTC] ICE state changed: %{public}@ -> connected=%{public}@",
               stringFromICEState(newState), connected ? "YES" : "NO")
        Task { @MainActor in
            self._connectionState = newState
            self._isConnected = connected
            self.onStateChange?(newState, connected)
            self.delegate?.webrtcDidChangeState(newState)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didChange newState: RTCIceGatheringState) {
        print("[WebRTC] ICE gathering: \(newState.rawValue)")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didGenerate candidate: RTCIceCandidate) {
        let target = self.hostID.isEmpty ? (self.signalingService.roomID ?? "") : self.hostID
        self.signalingService.sendICECandidate(
            targetID: target,
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex
        )
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didRemove candidates: [RTCIceCandidate]) {
        print("[WebRTC] ICE candidates removed")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didOpen dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel opened: \(dataChannel.label)")
        Task { @MainActor in
            self.setupDataChannel(dataChannel)
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                       didChange newState: RTCPeerConnectionState) {
        print("[WebRTC] Connection state: \(newState.rawValue)")
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCService: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[DataChannel] \(dataChannel.label) state: \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open && dataChannel.label == "auth" {
            Task { @MainActor in
                self.sendAuthData()
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel,
                    didReceiveMessageWith buffer: RTCDataBuffer) {
        let label = dataChannel.label

        switch label {
        case "terminal":
            Task { @MainActor in
                self.delegate?.webrtcDidReceiveTerminalData(buffer.data)
            }

        case "clipboard":
            if let msg = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               let payload = msg["payload"] as? [String: Any],
               let text = payload["text"] as? String {
                Task { @MainActor in
                    self.delegate?.webrtcDidReceiveClipboardData(text)
                }
            }

        case "auth":
            if let msg = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               let type = msg["type"] as? String,
               type == "auth_ok" {
                Task { @MainActor in
                    self.delegate?.webrtcDidAuthenticate()
                }
            }

        case "screen":
            break

        default:
            break
        }
    }
}

// MARK: - Helper

func stringFromICEState(_ state: RTCIceConnectionState) -> String {
    switch state {
    case .new: return "new"
    case .checking: return "checking"
    case .connected: return "connected"
    case .completed: return "completed"
    case .failed: return "failed"
    case .disconnected: return "disconnected"
    case .closed: return "closed"
    case .count: return "count"
    @unknown default: return "unknown(\(state.rawValue))"
    }
}
