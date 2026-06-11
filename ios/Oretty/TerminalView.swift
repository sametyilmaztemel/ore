import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var state: AppState
    @State private var output: [String] = []
    @State private var inputText = ""
    @State private var terminalBuffer = ""
    @State private var rows: Int = 24
    @State private var cols: Int = 80
    // FIX: Key-up timers to prevent stacking of key events
    @State private var keyUpTimers: [String: DispatchWorkItem] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(state.webrtc.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(state.connectedHost ?? "Terminal")
                    .fontWeight(.medium)
                Spacer()
                Button("Screen") {
                    state.activeView = .screen
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.ultraThinMaterial)

            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminalBuffer)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Color(white: 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }