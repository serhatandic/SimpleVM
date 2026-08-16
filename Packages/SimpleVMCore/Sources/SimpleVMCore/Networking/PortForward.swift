import Foundation

public struct PortForward: Identifiable, Codable, Hashable, Sendable {
    public enum Transport: String, Codable, Sendable {
        case tcp
    }

    public let id: UUID
    public var hostPort: UInt16
    public var guestPort: UInt16
    public var transport: Transport

    public init(
        id: UUID = UUID(),
        hostPort: UInt16,
        guestPort: UInt16,
        transport: Transport = .tcp
    ) {
        self.id = id
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.transport = transport
    }
}

public enum PortForwardValidator {
    public static func validate(_ forward: PortForward) throws {
        guard forward.hostPort > 0, forward.guestPort > 0 else {
            throw PortForwardError.invalidPort
        }
    }
}

public enum PortForwardError: LocalizedError, Equatable {
    case invalidPort

    public var errorDescription: String? {
        "Port numbers must be between 1 and 65535."
    }
}

