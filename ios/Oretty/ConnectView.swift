import SwiftUI
@preconcurrency import AVFoundation
import AudioToolbox

struct ConnectView: View {
    @EnvironmentObject var state: AppState
    @State private var signalURL = "wss://161.118.185.63:443"
    @State private var showQRScanner = false
    @State private var pairCode = ""
    @State private var showPicker = false
    @State private var selectedMode: ConnectionMode = .pairing

    enum ConnectionMode: String, CaseIterable {
        case pairing = "Pairing Code"
        case hosts = "Select Host"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo area
            VStack(spacing: 8) {
                Image(systemName: "display.2")
                    .font(.system(size: 48))
                    .foregroundColor(.purple)
                Text("Oretty")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Remote Mac Control")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Connection phase indicator
                connectionPhaseIndicator
                    .padding(.top, 8)
            }

            Spacer()

            // Connection form
            VStack(spacing: 16) {
                // Mode picker
                Picker("Mode", selection: $selectedMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 32)

                if selectedMode == .pairing {
                    pairingModeView
                } else {
                    hostsModeView
                }

                // Error message
                if let error = state.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal, 32)

            // Bottom buttons
            HStack(spacing: 20) {
                if state.connectionPhase == .disconnected {
                    Button("Scan QR") {
                        QRScannerViewController.checkCameraPermission { granted in
                            if granted {
                                showQRScanner = true
                            } else {
                                state.connectionError = "Camera access needed for QR scanning"
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Settings") {
                        state.activeView = .settings
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Disconnect") {
                        state.disconnectAll()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }

            Spacer()
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                pairCode = code
                showQRScanner = false
                submitPairing()
            }
        }
    }

    // MARK: - Connection Phase Indicator

    @ViewBuilder
    private var connectionPhaseIndicator: some View {
        switch state.connectionPhase {
        case .disconnected:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Connecting to signaling...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .registering:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Registering...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .pairing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Verifying pairing code...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .joiningRoom:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Connecting to host...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .negotiating:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Establishing secure connection...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Pairing Mode

    @ViewBuilder
    private var pairingModeView: some View {
        VStack(spacing: 16) {
            TextField("Signaling Server", text: $signalURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .disabled(state.connectionPhase != .disconnected)

            HStack(spacing: 12) {
                TextField("Pairing Code", text: $pairCode)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))