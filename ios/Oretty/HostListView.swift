import SwiftUI

struct HostListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Macs")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.connectionPhase != .connected && state.connectionPhase != .pairing)
            }
            .padding()

            // Host list
            if state.signaling.hosts.isEmpty && state.signaling.isConnected {
                Spacer()
                ProgressView("Scanning...")
                Spacer()
            } else if state.signaling.hosts.isEmpty {
                Spacer()
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No Macs found")
                    .font(.title2)
                    .padding(.top)
                Text("Make sure your Mac is online\nand the Oretty daemon is running")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(state.signaling.hosts) { host in
                    Button(action: { connectToHost(host) }) {
                        HostListRow(host: host)
                    }
                    .listRowBackground(Color(.systemGray6))
                }
            }

            // Bottom bar
            HStack {
                Button(action: disconnect) {
                    Label("Disconnect", systemImage: "power")
                }
                .foregroundColor(.red)
                Spacer()
                connectionStatus
            }
            .padding()
            .background(Color(.systemGray6))
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch state.connectionPhase {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .connecting, .registering, .pairing, .joiningRoom, .negotiating:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Connecting...")
                    .font(.caption)
            }
        case .failed(let error):
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        case .disconnected:
            Text("Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func refresh() {
        state.refreshHosts()
    }

    private func connectToHost(_ host: RemoteHostInfo) {
        state.connectedHost = host.name ?? host.deviceID
        state.connectToHost(host.deviceID)

        // Wait for WebRTC connection then show screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if state.webrtc.isConnected {
                state.activeView = .screen
            } else {
                // Still negotiating, wait more
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    state.activeView = .screen
                }
            }
        }
    }

    private func disconnect() {
        state.disconnectAll()
    }
}

struct HostListRow: View {
    let host: RemoteHostInfo

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(host.online ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name ?? host.deviceID)
                    .fontWeight(.semibold)
                if let platform = host.platform {
                    Text(platform)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HostListView()
        .environmentObject(AppState())
}
