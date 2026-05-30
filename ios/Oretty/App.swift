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