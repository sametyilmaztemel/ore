import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            switch state.activeView {
            case .connect:
                ConnectView()
            case .hosts:
                HostListView()
            case .screen:
                ScreenView()
            case .terminal:
                TerminalView()
            case .settings:
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
