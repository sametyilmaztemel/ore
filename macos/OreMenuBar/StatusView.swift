import SwiftUI

// MARK: - Status Tab

public struct StatusView: View {
    @ObservedObject var viewModel: OreViewModel
    @Binding var showPasswordField: Bool

    public init(viewModel: OreViewModel, showPasswordField: Binding<Bool>) {
        self.viewModel = viewModel
        self._showPasswordField = showPasswordField
    }

    public var body: some View {
        VStack(spacing: 16) {
            // ── Status Header ──────────────────────
            statusHeader

            // ── Helper / Unlock Section ────────────
            if !viewModel.helper.isHelperInstalled {
                helperNotInstalledView
            } else if viewModel.screenLocked {
                unlockFormView
            } else if viewModel.helper.isHelperInstalled {
                screenActionButtons
            }

            // ── Pairing Code & QR ─────────────────
            pairingSection

            // ── Connected Devices ──────────────────
            connectedDevicesCount

            // ── Quick Actions ──────────────────────
            quickActionsSection
        }
        .padding(.bottom, 8)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.status == .connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(viewModel.status == .connected ? .green : .red)

            if viewModel.isLoadingStatus {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting...")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
            } else {
                Text(viewModel.status.rawValue)
                    .font(.headline)
            }

            if let error = viewModel.statusError, viewModel.status == .disconnected {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            // Lock status
            HStack(spacing: 4) {
                Image(systemName: viewModel.screenLocked ? "lock.fill" : "lock.open.fill")
                    .font(.caption)
                Text(viewModel.screenLocked ? "Screen Locked" : "Screen Unlocked")
                    .font(.caption)
            }
            .foregroundColor(viewModel.screenLocked ? .orange : .green)
        }
        .padding(.top, 16)
    }

    // MARK: - Helper Not Installed

    private var helperNotInstalledView: some View {
        VStack(spacing: 8) {
            Text("Privileged Helper Not Installed")
                .font(.caption)
                .foregroundColor(.orange)
            Text("Required for lock screen unlock & screen capture")
                .font(.caption2)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: viewModel.installHelperTool) {
                if viewModel.isInstallingHelper {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 20)
                } else {
                    Label("Install Helper", systemImage: "lock.shield")
                        .font(.callout)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(viewModel.isInstallingHelper ? Color.gray : Color.purple)
            .cornerRadius(8)
            .disabled(viewModel.isInstallingHelper)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Unlock Form

    private var unlockFormView: some View {
        VStack(spacing: 8) {
            Text("Enter Mac Password to Unlock")
                .font(.caption)
                .foregroundColor(.gray)

            SecureField("Password", text: $viewModel.unlockPassword)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.15))
                .cornerRadius(6)
                .onSubmit {
                    viewModel.performUnlock()
                }

            if let error = viewModel.unlockError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            if viewModel.unlockSuccess {
                Label("Unlocked!", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Button(action: viewModel.performUnlock) {
                if viewModel.isUnlocking {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 20)
                } else {
                    Label("Unlock", systemImage: "lock.open.fill")
                        .font(.callout)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(viewModel.unlockPassword.isEmpty ? Color.gray : Color.purple)
            .cornerRadius(8)
            .disabled(viewModel.unlockPassword.isEmpty || viewModel.isUnlocking)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Screen Action Buttons

    private var screenActionButtons: some View {
        VStack(spacing: 10) {
            // Captured image preview
            if let capturedImage = viewModel.capturedImage {
                Image(nsImage: capturedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 180)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                    )
            }

            HStack(spacing: 12) {
                // Capture Screen button
                Button(action: viewModel.performCaptureScreen) {
                    if viewModel.isCapturing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20, height: 20)
                    } else {
                        Label("Capture", systemImage: "camera.viewfinder")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.purple)
                .cornerRadius(6)
                .disabled(viewModel.isCapturing)

                // Lock Screen button (if not already locked)
                if !viewModel.screenLocked {
                    Button(action: viewModel.performLockScreen) {
                        Label("Lock", systemImage: "lock.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .cornerRadius(6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pairing Section (QR + Code + Refresh)

    private var pairingSection: some View {
        VStack(spacing: 8) {
            Text("Pairing Code")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                Text(viewModel.pairCode)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                    .tracking(4)
                    .foregroundColor(.purple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Button(action: viewModel.copyPairCode) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.gray)

                // FIX: Refresh (yenile) button
                Button(action: {
                    Task { await viewModel.refreshPairCode() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
                .help("Generate new pairing code")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(8)

            // QR Code — bigger (200x200)
            if let qrImage = viewModel.pairQRImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 200, height: 200)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .frame(width: 200, height: 200)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 80))
                            .foregroundColor(.black)
                    )
            }

            // FIX: Scan hint text
            Text("Scan with iOS app to connect")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.7))
        }
    }

    // MARK: - Connected Devices Count

    private var connectedDevicesCount: some View {
        HStack {
            Image(systemName: "link.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text("\(viewModel.connectedDevices.count) device(s) connected")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(spacing: 12) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            // Disconnect All button
            Button(action: viewModel.disconnectAll) {
                HStack {
                    Image(systemName: "power")
                    Text("Disconnect All")
                }
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }
}
