import SwiftUI
import ServiceManagement

@main
struct OreMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var viewModel = OreViewModel()
    private var pollingTimer: Timer?
    private var pollingTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item - use variable length to show badge count
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Use custom "O" icon — draw a simple circle with "O" text
            let iconImage = NSImage(size: NSSize(width: 18, height: 18))
            iconImage.lockFocus()
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            // Background circle
            NSColor.white.setFill()
            let circlePath = NSBezierPath(ovalIn: rect)
            circlePath.fill()
            // Letter O
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle
            ]
            let letter = NSAttributedString(string: "O", attributes: attrs)
            let strRect = NSRect(x: 0, y: 1, width: 18, height: 18)
            letter.draw(in: strRect)
            iconImage.unlockFocus()
            button.image = iconImage
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(viewModel: viewModel)
        )

        // Register as launch-on-login (best effort)
        try? SMAppService.mainApp.register()

        // Connect to orettyd via local API
        viewModel.connectToDaemon()

        // Start polling status every 5 seconds for badge updates
        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTimer?.invalidate()
        pollingTimer = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Dispatch back to MainActor explicitly
            Task { @MainActor in
                self.pollingTask?.cancel()
                self.pollingTask = Task {
                    await self.viewModel.fetchStatus()
                    self.updateBadge()
                }
            }
        }
        // Initial badge update
        updateBadge()
    }

    func updateBadge() {
        guard let button = statusItem.button else { return }
        let count = viewModel.connectedDevices.count
        if count > 0 {
            button.title = " \(min(count, 99))"
        } else {
            button.title = ""
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}

// MARK: - Custom MenuBar View

struct MenuBarView: View {
    @ObservedObject var viewModel: OreViewModel
    @State private var selectedTab: Tab = .status
    @State private var showPasswordField = false

    enum Tab: String, CaseIterable {
        case status = "Status"
        case devices = "Devices"
        case settings = "Settings"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Custom Header ──────────────────
            headerView

            // ── Tab Bar ─────────────────────────
            tabBarView

            Divider()

            // ── Content ─────────────────────────
            ScrollView {
                switch selectedTab {
                case .status:
                    StatusView(viewModel: viewModel, showPasswordField: $showPasswordField)
                case .devices:
                    DevicesView(viewModel: viewModel)
                case .settings:
                    MacSettingsView(viewModel: viewModel)
                }
            }

            Divider()

            // ── Footer ──────────────────────────
            footerView
        }
        .frame(width: 340)
        .background(Color(white: 0.1))
        .foregroundColor(.white)
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "display.2")
                .font(.title3)
                .foregroundColor(.purple)
            Text("Ore")
                .font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
            Circle()
                .fill(viewModel.daemonRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.08))
    }

    private var tabBarView: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .purple : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(selectedTab == tab ? Color.purple.opacity(0.1) : Color.clear)
            }
        }
        .background(Color(white: 0.12))
    }

    private var footerView: some View {
        HStack {
            Text("Ore v1.0")
                .font(.caption2)
                .foregroundColor(.gray)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }
}

// MARK: - Preview

#Preview {
    MenuBarView(viewModel: OreViewModel())
        .frame(width: 340)
}
