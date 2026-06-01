import SwiftUI
import Combine
import UIKit

@main
struct OrettyApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}

class AppState: ObservableObject, @unchecked Sendable {
    @Published var isConnected = false
    @Published var connectedHost: String?
    @Published var activeView: ActiveView = .connect
    @Published var signalingURL = "wss://161.118.185.63:443"
    @Published var connectionError: String?

    let signaling: SignalingService
    let webrtc: WebRTCService

    @Published var connectionPhase: ConnectionPhase = .disconnected
    @Published var localDeviceID: String = ""

    enum ActiveView {
        case connect, hosts, screen, terminal, settings
    }

    enum ConnectionPhase: Equatable {
        case disconnected, connecting, registering, pairing
        case joiningRoom, negotiating, connected
        case failed(String)
    }

    private var cancellables = Set<AnyCancellable>()
    var autoPairingCode: String?

    init() {
        let sig = SignalingService()
        let wrtc = WebRTCService(signalingService: sig)
        signaling = sig
        webrtc = wrtc

        let currentDeviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        localDeviceID = currentDeviceID

        setupObservers()
    }

    private func setupObservers() {
        signaling.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                if connected {
                    self.connectionPhase = .registering
                    self.signaling.registerAsClient()
                } else {
                    self.connectionPhase = .disconnected
                }
            }
            .store(in: &cancellables)

        signaling.$registered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] registered in
                if registered {
                    self?.connectionPhase = .pairing
                    if let code = self?.autoPairingCode {
                        self?.autoPairingCode = nil
                        self?.pairWithCode(code)
                    }
                }
            }
            .store(in: &cancellables)

        signaling.$inRoom
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inRoom in
                if inRoom {
                    self?.connectionPhase = .negotiating
                }
            }
            .store(in: &cancellables)

        signaling.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.connectionError = error
                    self?.connectionPhase = .failed(error)
                }
            }
            .store(in: &cancellables)

        webrtc.onConnectionStateChange { [weak self] _, connected in
            if connected {
                self?.connectionPhase = .connected
                self?.isConnected = true
                self?.activeView = .screen
            }
        }
    }

    func connectToSignaling() {
        connectionPhase = .connecting
        connectionError = nil
        signaling.connect(url: signalingURL)
    }

    func disconnectAll() {
        webrtc.disconnect()
        signaling.disconnect()
        isConnected = false
        connectedHost = nil
        connectionPhase = .disconnected
        activeView = .connect
    }

    func pairWithCode(_ code: String) {
        connectionPhase = .pairing
        let baseURL = signalingURL
            .replacingOccurrences(of: "/ws", with: "")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        signaling.pairWithCode(code: code, serverURL: baseURL) { [weak self] success, _, hostID, roomID in
            guard let self = self else { return }
            if success, let hostID = hostID, let roomID = roomID {
                // Initialize WebRTC peer connection BEFORE joining room
                // so we're ready to receive the offer immediately
                self.webrtc.connect(targetID: hostID)
                self.connectionPhase = .joiningRoom
                self.signaling.joinRoom(roomID: roomID)
            } else if success, let hostID = hostID {
                self.webrtc.connect(targetID: hostID)
                self.connectionPhase = .joiningRoom
                self.signaling.joinRoom(roomID: hostID)
            } else {
                self.connectionPhase = .failed("Invalid pairing code")
            }
        }
    }

    func connectToHost(_ hostID: String) {
        self.webrtc.connect(targetID: hostID)
        connectionPhase = .joiningRoom
        signaling.joinRoom(roomID: hostID)
    }

    func refreshHosts() {
        let baseURL = signalingURL.replacingOccurrences(of: "/ws", with: "")
        signaling.fetchHostList(from: baseURL)
    }
}
