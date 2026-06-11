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
                .background(Color(white: 0.08))
                .onChange(of: terminalBuffer.count) { _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }

            // Input bar
            HStack(spacing: 8) {
                TextField(">", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)

                Button("Send") {
                    sendCommand(inputText)
                    inputText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty || !state.webrtc.isConnected)
            }
            .padding(8)
            .background(.ultraThinMaterial)

            // Toolbar
            HStack(spacing: 0) {
                ToolbarButton(title: "⎋") { sendKey("esc") }
                ToolbarButton(title: "⇥") { sendKey("tab") }
                ToolbarButton(title: "⌃") { sendKey("ctrl") }
                ToolbarButton(title: "⌘") { sendKey("cmd") }
                Spacer()
                ToolbarButton(systemName: "keyboard") { }
                ToolbarButton(systemName: "xmark") { state.activeView = .hosts }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
        .onAppear(perform: setupTerminal)
        .onDisappear(perform: cleanupTerminal)
    }

    private func setupTerminal() {
        if state.webrtc.isConnected {
            terminalBuffer = "[Connected to \(state.connectedHost ?? "Mac")]\n"
            // Send resize
            state.webrtc.sendResize(rows: rows, cols: cols)
        } else {
            terminalBuffer = "[Waiting for connection...]\n"
        }
    }

    private func cleanupTerminal() {
        // No cleanup needed
    }

    private func sendCommand(_ cmd: String) {
        guard state.webrtc.isConnected else { return }
        // Send the command followed by newline
        state.webrtc.sendTerminalInput(cmd + "\n")
    }

    // FIX: Send key with cancellable up timer to prevent stacking
    private func sendKey(_ key: String) {
        state.webrtc.sendKeyEvent(key: key, down: true)

        // Cancel any pending up event for this key
        keyUpTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak state = self.state] in
            state?.webrtc.sendKeyEvent(key: key, down: false)
        }
        keyUpTimers[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
}

#Preview {
    TerminalView()
        .environmentObject(AppState())
}
