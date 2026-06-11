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