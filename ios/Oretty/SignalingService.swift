import Foundation
import UIKit
import Combine

// MARK: - Signaling Protocol Types

enum SignalingMessageType: String {
    case register = "register"
    case registered = "registered"
    case heartbeat = "heartbeat"
    case createRoom = "create_room"
    case roomCreated = "room_created"
    case joinRoom = "join_room"
    case joinedRoom = "joined_room"
    case signal = "signal"
    case leaveRoom = "leave_room"
    case peerJoined = "peer_joined"
    case peerLeft = "peer_left"
    case error = "error"
    case hostList = "host_list"
    case connect = "connect"
}

struct SignalingMessage: Codable {
    let type: String
    let payload: [String: JSONValue]?
}

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    func toRawAny() -> Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let dict): return dict.mapValues { $0.toRawAny() }
        case .array(let arr): return arr.map { $0.toRawAny() }
        case .null: return NSNull()
        }
    }

    var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

// MARK: - Host Info

struct RemoteHostInfo: Identifiable, Codable {
    let deviceID: String
    let name: String?
    let platform: String?
    let arch: String?
    let version: String?
    let features: [String]?
    let online: Bool

    var id: String { deviceID }
}

// MARK: - Signaling Service

class SignalingService: ObservableObject, @unchecked Sendable {
    @Published var isConnected = false
    @Published var registered = false
    @Published var inRoom = false
    @Published var roomID: String?
    @Published var hosts: [RemoteHostInfo] = []
    @Published var errorMessage: String?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let queue = DispatchQueue(label: "signaling.queue")
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var deviceID: String = ""
    private var signalHandlers: [String: (SignalingMessage) -> Void] = [:]

    init() {
        deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    var onSignalMessage: ((String, [String: Any]) -> Void)?
    var onPeerJoined: (() -> Void)?
    var onPeerLeft: (() -> Void)?

    // MARK: - Connection

    func connect(url: String) {
        let wsURL = url.hasSuffix("/ws") ? url : url + "/ws"
        guard let url = URL(string: wsURL) else {
            errorMessage = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.default
        // Allow WSS with self-signed certs
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: SignalingSessionDelegate(owner: self), delegateQueue: nil)

        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()
    }

    // Called when the WebSocket connection opens (from delegate)
    func onConnected() {
        Task { @MainActor [weak self] in
            self?.isConnected = true
        }
        receiveMessage()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil

        Task { @MainActor [weak self] in
            self?.isConnected = false
            self?.registered = false
            self?.inRoom = false
            self?.roomID = nil
        }
    }

    // MARK: - Registration

    func registerAsClient() {
        sendMessage(type: "register", payload: [
            "device_id": .string(deviceID),
            "is_host": .bool(false)
        ])
    }

    // MARK: - Room Management

    func createRoom(name: String) {
        sendMessage(type: "create_room", payload: [
            "room_name": .string(name)
        ])
    }

    func joinRoom(roomID: String) {
        sendMessage(type: "join_room", payload: [
            "room_id": .string(roomID)
        ])
    }

    func leaveRoom() {
        sendMessage(type: "leave_room", payload: nil)
        Task { @MainActor [weak self] in
            self?.inRoom = false
            self?.roomID = nil
        }
    }

    // MARK: - WebRTC Signaling Relay

    func sendSignal(targetID: String, data: [String: Any]) {
        var payload: [String: JSONValue] = [
            "target_id": .string(targetID)
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            // Convert data dict to JSONValue object
            var signalDict: [String: JSONValue] = [:]
            for (k, v) in data {
                signalDict[k] = jsonToValue(v)
            }
            payload["data"] = .object(signalDict)
        }
        sendMessage(type: "signal", payload: payload)
    }

    func sendSignalSDP(targetID: String, type: String, sdp: String) {
        let payload: [String: JSONValue] = [
            "target_id": .string(targetID),
            "data": .object([
                "type": .string(type),
                "sdp": .string(sdp)
            ])
        ]
        sendMessage(type: "signal", payload: payload)
    }

    func sendICECandidate(targetID: String, candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        let payload: [String: JSONValue] = [
            "target_id": .string(targetID),
            "data": .object([
                "type": .string("ice_candidate"),
                "candidate": .string(candidate),
                "sdpMid": .string(sdpMid),
                "sdpMLineIndex": .number(Double(sdpMLineIndex))
            ])
        ]
        sendMessage(type: "signal", payload: payload)
    }

    // MARK: - Host List (REST)

    func fetchHostList(from url: String) {
        guard let apiURL = URL(string: url + "/api/hosts") else { return }

        // Use a session that accepts self-signed TLS certs
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SignalingSessionDelegate(owner: self), delegateQueue: nil)
        session.dataTask(with: apiURL) { [weak self] data, _, error in
            session.invalidateAndCancel()
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hostsArray = json["hosts"] as? [[String: Any]] else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.hosts = hostsArray.compactMap { dict in
                    guard let deviceID = dict["device_id"] as? String else { return nil }
                    return RemoteHostInfo(
                        deviceID: deviceID,
                        name: dict["name"] as? String,
                        platform: dict["platform"] as? String,
                        arch: dict["arch"] as? String,
                        version: dict["version"] as? String,
                        features: dict["features"] as? [String],
                        online: true
                    )
                }
            }
        }.resume()
    }

    // MARK: - Pairing (REST)

    func pairWithCode(code: String, serverURL: String, completion: @escaping (Bool, String?, String?, String?) -> Void) {
        guard let apiURL = URL(string: serverURL + "/api/pair") else {
            completion(false, nil, nil, nil)
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])

        // Use a session that accepts self-signed TLS certs
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SignalingSessionDelegate(owner: self), delegateQueue: nil)
        session.dataTask(with: request) { data, _, error in
            session.invalidateAndCancel()
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(false, nil, nil, nil)
                }
                return
            }

            let success = json["success"] as? Bool ?? false
            let deviceID = json["device_id"] as? String
            let hostID = json["host_id"] as? String
            let roomID = json["room_id"] as? String
            DispatchQueue.main.async {
                completion(success, deviceID, hostID, roomID)
            }
        }.resume()
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.errorMessage = "WebSocket error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        let payload = json["payload"] as? [String: Any] ?? [:]

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.processMessage(type: type, payload: payload)
        }
    }

    private func processMessage(type: String, payload: [String: Any]) {
        switch type {
        case "registered":
            registered = true
            // Start heartbeat
            startHeartbeat()

        case "room_created":
            if let roomID = payload["room_id"] as? String {
                self.roomID = roomID
                inRoom = true
            }

        case "joined_room":
            if let roomID = payload["room_id"] as? String {
                self.roomID = roomID
                inRoom = true
            }

        case "signal":
            if let data = payload["data"] as? [String: Any] {
                let senderID = payload["sender_id"] as? String ?? ""
                onSignalMessage?(senderID, data)
            }

        case "peer_joined":
            onPeerJoined?()

        case "peer_left":
            onPeerLeft?()
            inRoom = false

        case "error":
            errorMessage = payload["message"] as? String ?? "Unknown error"

        default:
            break
        }
    }

    // MARK: - Send

    private func sendMessage(type: String, payload: [String: JSONValue]?) {
        var message: [String: Any] = ["type": type]
        if let payload = payload {
            message["payload"] = payload.mapValues { $0.toRawAny() }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Send error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.sendMessage(type: "heartbeat", payload: nil)
        }
    }

    // MARK: - Helpers

    private func jsonToValue(_ value: Any) -> JSONValue {
        if let str = value as? String { return .string(str) }
        if let num = value as? Double { return .number(num) }
        if let num = value as? Int { return .number(Double(num)) }
        if let bool = value as? Bool { return .bool(bool) }
        if let dict = value as? [String: Any] {
            var result: [String: JSONValue] = [:]
            for (k, v) in dict { result[k] = jsonToValue(v) }
            return .object(result)
        }
        if let arr = value as? [Any] {
            return .array(arr.map { jsonToValue($0) })
        }
        return .null
    }
}

// MARK: - URLSession WebSocket Delegate (for self-signed TLS + connection detection)

class SignalingSessionDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: SignalingService?

    init(owner: SignalingService) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept self-signed certificates for dev
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        owner?.onConnected()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            self?.owner?.isConnected = false
            self?.owner?.errorMessage = "Connection closed: \(closeCode)"
        }
    }
}
