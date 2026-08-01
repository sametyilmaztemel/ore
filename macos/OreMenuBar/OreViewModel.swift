import Foundation
import SwiftUI
import CoreImage

// MARK: - View Model

@MainActor
public class OreViewModel: ObservableObject {
    @Published public var daemonRunning = false
    @Published public var connectedDevices: [DeviceInfo] = []
    @Published public var pairCode = "------"
    @Published public var status: DaemonStatus = .disconnected
    @Published public var screenLocked = false
    @Published public var unlockPassword = ""
    @Published public var isUnlocking = false
    @Published public var unlockError: String?
    @Published public var unlockSuccess = false

    // QR code image (generated from pairCode)
    @Published public var pairQRImage: NSImage?

    // Capture/Lock screen state
    @Published public var capturedImage: NSImage?
    @Published public var isCapturing = false

    // Loading & error states
    @Published public var isLoadingStatus = false
    @Published public var statusError: String?
    @Published public var isInstallingHelper = false

    public let helper = HelperManager()

    public enum DaemonStatus: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case error = "Error"
    }

    public struct DeviceInfo: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let connectedAt: Date

        public init(id: String, name: String, connectedAt: Date) {
            self.id = id
            self.name = name
            self.connectedAt = connectedAt
        }
    }

    public init() {}

    // MARK: - Daemon Connection

    public func connectToDaemon() {
        Task { [weak self] in
            guard let self else { return }
            await fetchStatus()
            let locked = await helper.isScreenLocked()
            await MainActor.run {
                self.screenLocked = locked
            }
        }
    }

    public func disconnectAll() {
        connectedDevices.removeAll()
        Task { [weak self] in
            guard let self else { return }
            guard let url = URL(string: "http://127.0.0.1:9876/api/disconnect") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    self.connectedDevices.removeAll()
                }
            } catch {}
        }
    }

    // MARK: - Local API

    public func fetchStatus() async {
        isLoadingStatus = true
        statusError = nil

        guard let url = URL(string: "http://127.0.0.1:9876/api/status") else {
            isLoadingStatus = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                self.status = .disconnected
                self.daemonRunning = false
                self.statusError = "API returned error"
                self.isLoadingStatus = false
                return
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.daemonRunning = json["daemon_running"] as? Bool ?? false
                self.status = self.daemonRunning ? .connected : .disconnected
                if let code = json["pair_code"] as? String, !code.isEmpty {
                    self.pairCode = code
                    self.refreshQR()
                }
                // Parse connected devices count from API
                if let count = json["connected_devices"] as? Int {
                    let currentCount = self.connectedDevices.count
                    if currentCount != count {
                        if count == 0 {
                            self.connectedDevices = []
                        } else if currentCount < count {
                            // Add placeholder devices for new connections
                            for i in currentCount..<count {
                                self.connectedDevices.append(
                                    DeviceInfo(id: "device-\(i)", name: "Device \(i + 1)", connectedAt: Date())
                                )
                            }
                        } else {
                            // Remove excess placeholders
                            self.connectedDevices = Array(self.connectedDevices.prefix(count))
                        }
                    }
                }
            }
            isLoadingStatus = false
        } catch {
            self.status = .disconnected
            self.daemonRunning = false
            self.statusError = error.localizedDescription
            self.isLoadingStatus = false
        }
    }

    public func fetchPairCode() async {
        guard let url = URL(string: "http://127.0.0.1:9876/api/paircode") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? String {
                self.pairCode = code
                self.refreshQR()
            }
        } catch {}
    }

    // MARK: - Pair Code Refresh

    public func refreshPairCode() async {
        guard let url = URL(string: "http://127.0.0.1:9876/api/paircode/refresh") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? String {
                self.pairCode = code
                self.refreshQR()
            }
        } catch {}
    }

    public func copyPairCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairCode, forType: .string)
    }

    // MARK: - QR Code

    public func refreshQR() {
        guard !pairCode.isEmpty, pairCode != "------" else { return }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        let data = pairCode.data(using: .utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let qrImage = filter.outputImage else { return }

        let scale: CGFloat = 10.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledQR = qrImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledQR)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        self.pairQRImage = nsImage
    }

    // MARK: - Screen Capture & Lock

    public func performCaptureScreen() {
        guard helper.isHelperInstalled else { return }
        isCapturing = true
        Task { [weak self] in
            guard let self else { return }
            if let data = await helper.captureDisplay() {
                await MainActor.run {
                    self.capturedImage = NSImage(data: data)
                    self.isCapturing = false
                }
            } else {
                await MainActor.run {
                    self.isCapturing = false
                }
            }
        }
    }

    public func performLockScreen() {
        Task { [weak self] in
            guard let self else { return }
            let success = await helper.lockScreen()
            await MainActor.run {
                if success {
                    self.screenLocked = true
                }
            }
        }
    }

    // MARK: - Lock Screen

    public func checkScreenLocked() {
        Task { [weak self] in
            guard let self else { return }
            let locked = await helper.isScreenLocked()
            await MainActor.run {
                self.screenLocked = locked
            }
        }
    }

    public func performUnlock() {
        guard !unlockPassword.isEmpty else { return }
        isUnlocking = true
        unlockError = nil
        unlockSuccess = false

        Task { [weak self] in
            guard let self else { return }
            let success = await helper.unlock(password: unlockPassword)
            await MainActor.run {
                self.isUnlocking = false
                self.unlockSuccess = success
                if !success {
                    self.unlockError = "Failed to unlock. Check password."
                } else {
                    self.unlockPassword = ""
                    self.screenLocked = false
                    // Auto-clear success after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.unlockSuccess = false
                    }
                }
            }
        }
    }

    // MARK: - Helper Installation

    public func installHelperTool() {
        guard !isInstallingHelper else { return }
        isInstallingHelper = true
        Task { [weak self] in
            guard let self else { return }
            let success = await helper.installHelper()
            await MainActor.run {
                self.isInstallingHelper = false
                if !success {
                    self.unlockError = self.helper.lastError ?? "Installation failed"
                } else {
                    self.unlockError = nil
                }
            }
        }
    }
}
