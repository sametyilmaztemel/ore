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