import Foundation

public enum GuestAgentRequest: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    case status
    case shutdown
    case reboot
}

public struct GuestAgentStatus: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let hostname: String
    public let ipAddresses: [String]
    public let operatingSystem: String
    public let sharedDirectories: [String]

    public init(
        protocolVersion: Int,
        hostname: String,
        ipAddresses: [String],
        operatingSystem: String,
        sharedDirectories: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.hostname = hostname
        self.ipAddresses = ipAddresses
        self.operatingSystem = operatingSystem
        self.sharedDirectories = sharedDirectories
    }
}

public enum GuestAgentResponse: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    case status(GuestAgentStatus)
    case accepted
    case failure(message: String)
}

public enum GuestAgentFrameCodec {
    public static let maximumPayloadSize = 1 * 1_024 * 1_024

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumPayloadSize else {
            throw GuestAgentProtocolError.payloadTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from frame: Data
    ) throws -> T {
        guard frame.count >= 4 else {
            throw GuestAgentProtocolError.incompleteFrame
        }
        let length = frame.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length <= maximumPayloadSize else {
            throw GuestAgentProtocolError.payloadTooLarge
        }
        guard frame.count == Int(length) + 4 else {
            throw GuestAgentProtocolError.incompleteFrame
        }
        return try JSONDecoder().decode(T.self, from: frame.dropFirst(4))
    }
}

public enum GuestAgentProtocolError: LocalizedError, Equatable {
    case payloadTooLarge
    case incompleteFrame

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "The guest-agent message exceeds the size limit."
        case .incompleteFrame:
            "The guest-agent message is incomplete."
        }
    }
}

