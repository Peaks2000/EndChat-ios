import Foundation
import SwiftUI

let maxSharedFileBytes: Int64 = 10 * 1024 * 1024 * 1024

enum MessageKind: String, Codable {
    case text
    case image
    case file
    case system
}

enum DeliveryState: String, Codable {
    case queued
    case sending
    case delivered
    case cancelled
    case failed
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var sender: String
    var body: String
    var date = Date()
    var isMine: Bool
    var kind: MessageKind
    var fileName: String?
    var fileSize: Int64?
    var localFilePath: String?
    var deliveryState: DeliveryState?
    var conversationID: String?
    var verifiedSender: Bool?

    static func system(_ body: String) -> ChatMessage {
        ChatMessage(sender: "EndChat", body: body, isMine: false, kind: .system)
    }
}

struct WireMessage: Codable {
    var id: UUID
    var sender: String
    var body: String
    var date: Date
    var kind: MessageKind
    var fileName: String?
    var fileSize: Int64?
    var senderIdentifier: String?
}

struct ChatThread: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var updatedAt = Date()
}

enum WireEnvelopeKind: String, Codable {
    case message
    case acknowledgement
}

struct WireEnvelope: Codable {
    var kind: WireEnvelopeKind
    var message: WireMessage?
    var acknowledgedID: UUID?

    static func message(_ message: WireMessage) -> WireEnvelope {
        WireEnvelope(kind: .message, message: message, acknowledgedID: nil)
    }

    static func acknowledgement(_ id: UUID) -> WireEnvelope {
        WireEnvelope(kind: .acknowledgement, message: nil, acknowledgedID: id)
    }
}

enum SecurePacketKind: String, Codable {
    case keyExchange
    case encrypted
}

struct SecurePacket: Codable {
    var kind: SecurePacketKind
    var publicKey: Data?
    var ciphertext: Data?
}

struct RelayPacket: Codable {
    var id: String
    var from: String
    var to: String
    var senderPublicKey: Data
    var ciphertext: Data
}

struct Contact: Identifiable, Codable, Equatable {
    var id = UUID()
    var peerIdentifier: String?
    var name: String
    var nickname: String?
    var note: String?
    var profileImageData: Data?
    var verifiedPublicKey: Data?
}

struct QRContactCard: Codable {
    static let scheme = "endchat://contact/"

    var version = 1
    var peerIdentifier: String
    var nickname: String
    var publicKey: Data?

    func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.scheme + data.base64EncodedString()
    }

    static func decode(_ value: String) -> QRContactCard? {
        let encoded = value.hasPrefix(scheme) ? String(value.dropFirst(scheme.count)) : value
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum WallpaperChoice: String, CaseIterable, Identifiable {
    case aurora
    case graphite
    case reef
    case ember
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .graphite: "Graphite"
        case .reef: "Reef"
        case .ember: "Ember"
        case .photo: "Photo"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .aurora:
            LinearGradient(colors: [.mint, .teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .graphite:
            LinearGradient(colors: [.black, .gray, .white.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        case .reef:
            LinearGradient(colors: [.cyan, .blue, .green], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ember:
            LinearGradient(colors: [.red, .orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .photo:
            LinearGradient(colors: [.indigo, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension Int64 {
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
