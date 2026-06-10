import SwiftUI
import WebRTC

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        Text("Signaling Server")
                        Spacer()
                        Text(state.signalingURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(state.localDeviceID.prefix(8) + "...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        connectionStatusLabel
                            .font(.caption)
                    }

                    if state.webrtc.isConnected {
                        HStack {
                            Text("ICE State")
                            Spacer()
                            Text(iceStateString(state.webrtc.connectionState))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Video") {
                    HStack {
                        Text("Codec")
                        Spacer()
                        Text("H.264")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("Adaptive")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("STUN")
                        Spacer()
                        Text("stun.l.google.com:19302")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("TURN")
                        Spacer()
                        Text("161.118.185.63:3478")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Terminal") {
                    HStack {
                        Text("PTY")
                        Spacer()
                        Text("bash/zsh")
                            .foregroundColor(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text("1")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("WebRTC")
                        Spacer()
                        Text("M" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        state.disconnectAll()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var connectionStatusLabel: some View {
        switch state.connectionPhase {
        case .disconnected:
            Label("Disconnected", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .connecting, .registering, .pairing, .joiningRoom, .negotiating:
            Label("Connecting...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundColor(.orange)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }

    private func iceStateString(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "New"
        case .checking: return "Checking"
        case .connected: return "Connected"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        case .closed: return "Closed"
        case .count: return "?"
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
