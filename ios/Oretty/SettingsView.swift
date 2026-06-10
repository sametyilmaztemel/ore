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