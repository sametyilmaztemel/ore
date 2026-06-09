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