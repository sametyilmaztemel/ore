import SwiftUI
import ServiceManagement

// MARK: - Settings Tab

public struct MacSettingsView: View {
    @ObservedObject var viewModel: OreViewModel
    @State private var signalURL = "wss://161.118.185.63:443"
    @State private var launchAtLogin = true
    @State private var showHelperInfo = false

    public init(viewModel: OreViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Privileged Helper
            helperSection

            // Connection
            connectionSection

            // Video
            videoSection

            // System
            systemSection

            // Reset
            resetButton
        }
        .padding(12)
    }

    // MARK: - Helper Section

    private var helperSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: viewModel.helper.isHelperInstalled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(viewModel.helper.isHelperInstalled ? .green : .red)
                    Text(viewModel.helper.isHelperInstalled ? "Installed" : "Not Installed")
                        .font(.callout)
                    Spacer()
                    Button(action: { showHelperInfo.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.gray)
                }

                if showHelperInfo {
                    Text("Runs as root to perform privileged operations:\nunlock screen, capture display, lock screen")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Text("Required for lock screen unlock and screen capture")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 8) {
                    Button(action: viewModel.installHelperTool) {
                        if viewModel.isInstallingHelper {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Install / Update")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.purple)
                    .disabled(viewModel.isInstallingHelper)

                    if viewModel.helper.isHelperInstalled {
                        Button(action: {
                            Task { await viewModel.helper.removeHelper() }
                        }) {
                            Text("Remove")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Privileged Helper", systemImage: "lock.shield")
                .font(.caption)
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Signaling Server")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack {
                    TextField("URL", text: $signalURL)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .disabled(true)
                    Text("(read-only)")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
            .padding(8)
        } label: {
            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
        }
    }

    // MARK: - Video Section

    private var videoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Codec status
                HStack {
                    Text("Codec")
                        .font(.callout)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("VP8")
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundColor(.green)
                        }
                        Text("H.264 🚧 H.265 📋")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                // FPS status
                HStack {
                    Text("Frame Rate")
                        .font(.callout)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("60 fps")
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundColor(.green)
                        }
                        Text("VP8 @ 720p — H.264 fix ile 60fps sabitlenir")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                // Resolution status
                HStack {
                    Text("Resolution")
                        .font(.callout)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("1280 × 720")
                            .font(.callout.monospacedDigit().weight(.medium))
                        Text("1920×1080 + 60fps planlanıyor")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                Divider()

                // Daemon info
                HStack {
                    Text("Daemon")
                        .font(.callout)
                    Spacer()
                    if viewModel.daemonRunning {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("Running")
                                .font(.callout)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("Offline")
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                    }
                }

                if let code = viewModel.pairCode.isEmpty ? nil : viewModel.pairCode {
                    HStack {
                        Text("Pair Code")
                            .font(.callout)
                        Spacer()
                        Text(code)
                            .font(.system(.callout, design: .monospaced, weight: .bold))
                            .foregroundColor(.purple)
                    }
                }

                // Note
                Text("H.264/H.265 hardware encode çalışmıyor (siyah ekran). VP8 pipeline kararlı. Çözüm bulununca codec seçeneği aktifleşecek.")
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        } label: {
            Label("Video Status", systemImage: "video")
                .font(.caption)
        }
    }

    // MARK: - System Section

    private var systemSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }

                Toggle("Lock Screen on Disconnect", isOn: .constant(false))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(true)
            }
            .padding(8)
        } label: {
            Label("System", systemImage: "gearshape")
                .font(.caption)
        }
    }

    // MARK: - Reset Button

    private var resetButton: some View {
        Button(action: {
            viewModel.pairCode = "ORE------"
            viewModel.pairQRImage = nil
        }) {
            HStack {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset Pairing")
            }
            .font(.callout)
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
