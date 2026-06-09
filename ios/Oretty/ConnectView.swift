import SwiftUI
@preconcurrency import AVFoundation
import AudioToolbox

struct ConnectView: View {
    @EnvironmentObject var state: AppState
    @State private var signalURL = "wss://161.118.185.63:443"
    @State private var showQRScanner = false
    @State private var pairCode = ""
    @State private var showPicker = false
    @State private var selectedMode: ConnectionMode = .pairing

    enum ConnectionMode: String, CaseIterable {
        case pairing = "Pairing Code"
        case hosts = "Select Host"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo area
            VStack(spacing: 8) {
                Image(systemName: "display.2")
                    .font(.system(size: 48))
                    .foregroundColor(.purple)
                Text("Oretty")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Remote Mac Control")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Connection phase indicator
                connectionPhaseIndicator
                    .padding(.top, 8)
            }

            Spacer()

            // Connection form
            VStack(spacing: 16) {
                // Mode picker
                Picker("Mode", selection: $selectedMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 32)

                if selectedMode == .pairing {
                    pairingModeView
                } else {
                    hostsModeView
                }

                // Error message
                if let error = state.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal, 32)

            // Bottom buttons
            HStack(spacing: 20) {
                if state.connectionPhase == .disconnected {
                    Button("Scan QR") {
                        QRScannerViewController.checkCameraPermission { granted in
                            if granted {
                                showQRScanner = true
                            } else {
                                state.connectionError = "Camera access needed for QR scanning"
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Settings") {
                        state.activeView = .settings
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Disconnect") {
                        state.disconnectAll()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }

            Spacer()
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                pairCode = code
                showQRScanner = false
                submitPairing()
            }
        }
    }

    // MARK: - Connection Phase Indicator

    @ViewBuilder
    private var connectionPhaseIndicator: some View {
        switch state.connectionPhase {
        case .disconnected:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Connecting to signaling...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .registering:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Registering...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .pairing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Verifying pairing code...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .joiningRoom:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Connecting to host...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .negotiating:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Establishing secure connection...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Pairing Mode

    @ViewBuilder
    private var pairingModeView: some View {
        VStack(spacing: 16) {
            TextField("Signaling Server", text: $signalURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .disabled(state.connectionPhase != .disconnected)

            HStack(spacing: 12) {
                TextField("Pairing Code", text: $pairCode)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.connectionPhase != .disconnected && state.connectionPhase != .pairing)

                Button(action: { showQRScanner = true }) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .disabled(state.connectionPhase != .disconnected)
            }

            Button(action: submitPairing) {
                if state.connectionPhase == .connecting || state.connectionPhase == .registering ||
                   state.connectionPhase == .pairing || state.connectionPhase == .joiningRoom ||
                   state.connectionPhase == .negotiating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text(state.connectionPhase == .connected ? "Connected" : "Connect")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Hosts Mode

    @ViewBuilder
    private var hostsModeView: some View {
        VStack(spacing: 12) {
            if state.connectionPhase == .disconnected {
                Button(action: startAndFetchHosts) {
                    Label("Connect & Find Hosts", systemImage: "antenna.radiowaves.left.and.right")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else if state.signaling.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning for hosts...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(state.signaling.hosts) { host in
                            Button(action: { connectToHost(host) }) {
                                HostRow(host: host)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        switch state.connectionPhase {
        case .disconnected:
            return !pairCode.isEmpty && !signalURL.isEmpty
        case .pairing:
            return !pairCode.isEmpty
        case .connecting, .registering, .joiningRoom, .negotiating:
            return false
        case .connected:
            return false
        case .failed:
            return true
        }
    }

    private func submitPairing() {
        guard !pairCode.isEmpty else { return }

        // Save URL
        state.signalingURL = signalURL

        switch state.connectionPhase {
        case .disconnected:
            // Connect to signaling first; pairing will auto-start when registered
            state.connectToSignaling()
            state.autoPairingCode = pairCode.uppercased()
        case .failed:
            // Clear error and try connecting
            state.connectToSignaling()
            state.autoPairingCode = pairCode.uppercased()
        case .pairing, .connecting, .registering:
            // Already connected/connecting, just pair directly
            state.pairWithCode(pairCode.uppercased())
        case .joiningRoom, .negotiating, .connected:
            break // Already in progress or connected
        }
    }

    private func startAndFetchHosts() {
        state.signalingURL = signalURL
        state.connectToSignaling()
        // Fetch hosts after connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            state.refreshHosts()
        }
    }

    private func connectToHost(_ host: RemoteHostInfo) {
        state.connectedHost = host.name ?? host.deviceID
        state.connectToHost(host.deviceID)
    }
}

// MARK: - Host Row

struct HostRow: View {
    let host: RemoteHostInfo

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(host.online ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name ?? host.deviceID)
                    .fontWeight(.semibold)
                if let platform = host.platform, let features = host.features {
                    Text("\(platform) · \(features.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = QRScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, QRScannerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }
        func didScan(code: String) {
            onScan(code)
        }
    }
}

// MARK: - QRScanner Delegate

protocol QRScannerDelegate: AnyObject {
    func didScan(code: String)
}

// MARK: - QRScanner ViewController (AVCaptureSession)

@MainActor
class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                       didOutput metadataObjects: [AVMetadataObject],
                       from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue,
              !stringValue.isEmpty else {
            return
        }

        // Vibrate feedback
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        // Call delegate via main actor
        Task { @MainActor [weak self] in
            self?.delegate?.didScan(code: stringValue)
        }
    }

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let scanFrame = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupScanOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds

        // Draw scan frame overlay
        let size: CGFloat = min(view.bounds.width * 0.7, 300)
        scanFrame.frame = CGRect(
            x: (view.bounds.width - size) / 2,
            y: (view.bounds.height - size) / 2,
            width: size,
            height: size
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCamera()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCamera()
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            showError("Camera not available")
            return
        }

        let session = AVCaptureSession()
        self.captureSession = session

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                showError("Cannot add camera input")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                showError("Cannot add metadata output")
                return
            }
            session.addOutput(output)

            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            self.previewLayer = preview
        } catch {
            showError("Camera error: \(error.localizedDescription)")
        }
    }

    private func startCamera() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    private func stopCamera() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    // MARK: - Scan Overlay

    private func setupScanOverlay() {
        scanFrame.layer.borderColor = UIColor.white.cgColor
        scanFrame.layer.borderWidth = 2
        scanFrame.layer.cornerRadius = 12
        scanFrame.backgroundColor = .clear
        view.addSubview(scanFrame)

        // Instruction label
        let label = UILabel()
        label.text = "Point camera at pairing QR code"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: scanFrame.bottomAnchor, constant: 24)
        ])

        // Close button
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeBtn.widthAnchor.constraint(equalToConstant: 44),
            closeBtn.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func dismissTapped() {
        dismiss(animated: true)
    }


    // MARK: - Error Display

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 32, dy: 0)
        view.addSubview(label)
    }
}

// MARK: - Camera Permission Helper

extension QRScannerViewController {
    static func checkCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}

#Preview {
    ConnectView()
        .environmentObject(AppState())
}
