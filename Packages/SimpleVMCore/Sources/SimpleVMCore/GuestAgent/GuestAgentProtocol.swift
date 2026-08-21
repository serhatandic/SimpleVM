import Foundation

public enum GuestAgentProtocol {
    public static let currentVersion = 2
    public static let agentPort: UInt32 = 1_021
    public static let qemuPortName = "com.simplevm.agent.0"
    public static let sharedDirectoryTag = "share"
    public static let sharedDirectoryMountPoint = "/mnt/simplevm-share"
    public static let maximumClipboardSize = 1 * 1_024 * 1_024
}

public enum GuestDesktopEnvironment: String, Codable, Equatable, Sendable {
    case gnome
    case hyprland
    case other
}

public enum GuestSessionType: String, Codable, Equatable, Sendable {
    case wayland
    case x11
    case other
}

public enum GuestAgentCapability: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case gracefulShutdown
    case gracefulReboot
    case mountSharedDirectory
    case clipboardRead
    case clipboardWrite
    case displayResize
}

public enum GuestSharedMountState: String, Equatable, Sendable {
    case unavailable
    case unmounted
    case mounted
    case failed
}

extension GuestSharedMountState: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "unavailable":
            self = .unavailable
        case "unmounted", "notMounted":
            self = .unmounted
        case "mounted":
            self = .mounted
        case "failed", "error", "occupied":
            self = .failed
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown shared-mount state \(value)."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GuestSharedMountStatus: Codable, Equatable, Sendable {
    public let state: GuestSharedMountState
    public let tag: String
    public let mountPoint: String
    public let message: String?

    public init(
        state: GuestSharedMountState,
        tag: String = GuestAgentProtocol.sharedDirectoryTag,
        mountPoint: String = GuestAgentProtocol.sharedDirectoryMountPoint,
        message: String? = nil
    ) {
        self.state = state
        self.tag = tag
        self.mountPoint = mountPoint
        self.message = message
    }
}

public enum GuestAgentRequest: Equatable, Sendable {
    case hello(protocolVersion: Int)
    case status
    case shutdown
    case reboot
    case mountSharedDirectory
    case readClipboard
    case writeClipboard(text: String)
    case resizeDisplay(width: Int, height: Int)
}

extension GuestAgentRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case text
        case width
        case height
        case hello
        case status
        case shutdown
        case reboot
    }

    private enum RequestType: String, Codable {
        case hello
        case status
        case shutdown
        case reboot
        case mountSharedDirectory
        case readClipboard
        case writeClipboard
        case resizeDisplay
    }

    private struct LegacyHello: Decodable {
        let protocolVersion: Int
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(
            RequestType.self,
            forKey: .type
        ) {
            switch type {
            case .hello:
                self = .hello(
                    protocolVersion: try container.decode(
                        Int.self,
                        forKey: .protocolVersion
                    )
                )
            case .status:
                self = .status
            case .shutdown:
                self = .shutdown
            case .reboot:
                self = .reboot
            case .mountSharedDirectory:
                self = .mountSharedDirectory
            case .readClipboard:
                self = .readClipboard
            case .writeClipboard:
                self = .writeClipboard(
                    text: try container.decode(String.self, forKey: .text)
                )
            case .resizeDisplay:
                self = .resizeDisplay(
                    width: try container.decode(Int.self, forKey: .width),
                    height: try container.decode(Int.self, forKey: .height)
                )
            }
        } else if let hello = try container.decodeIfPresent(
            LegacyHello.self,
            forKey: .hello
        ) {
            self = .hello(protocolVersion: hello.protocolVersion)
        } else if container.contains(.status) {
            self = .status
        } else if container.contains(.shutdown) {
            self = .shutdown
        } else if container.contains(.reboot) {
            self = .reboot
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown guest-agent request."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let protocolVersion):
            try container.encode(RequestType.hello, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case .status:
            try container.encode(RequestType.status, forKey: .type)
        case .shutdown:
            try container.encode(RequestType.shutdown, forKey: .type)
        case .reboot:
            try container.encode(RequestType.reboot, forKey: .type)
        case .mountSharedDirectory:
            try container.encode(
                RequestType.mountSharedDirectory,
                forKey: .type
            )
        case .readClipboard:
            try container.encode(RequestType.readClipboard, forKey: .type)
        case .writeClipboard(let text):
            guard text.utf8.count <= GuestAgentProtocol.maximumClipboardSize else {
                throw GuestAgentProtocolError.clipboardTooLarge
            }
            try container.encode(RequestType.writeClipboard, forKey: .type)
            try container.encode(text, forKey: .text)
        case .resizeDisplay(let width, let height):
            guard GuestDisplaySize.isValid(width: width, height: height) else {
                throw GuestAgentProtocolError.invalidDisplaySize
            }
            try container.encode(RequestType.resizeDisplay, forKey: .type)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }
}

public struct GuestAgentStatus: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let agentVersion: String
    public let hostname: String
    public let ipAddresses: [String]
    public let operatingSystem: String
    public let distroID: String
    public let distroVersion: String
    public let desktopEnvironment: GuestDesktopEnvironment
    public let sessionType: GuestSessionType
    public let capabilities: Set<GuestAgentCapability>
    public let sharedMountStatus: GuestSharedMountStatus

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case agentVersion
        case hostname
        case ipAddresses
        case operatingSystem
        case distroID
        case distroVersion
        case desktopEnvironment
        case sessionType
        case capabilities
        case sharedMountStatus
        case sharedDirectories
    }

    public init(
        protocolVersion: Int,
        agentVersion: String,
        hostname: String,
        ipAddresses: [String],
        operatingSystem: String,
        distroID: String,
        distroVersion: String,
        desktopEnvironment: GuestDesktopEnvironment,
        sessionType: GuestSessionType,
        capabilities: Set<GuestAgentCapability>,
        sharedMountStatus: GuestSharedMountStatus
    ) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.hostname = hostname
        self.ipAddresses = ipAddresses
        self.operatingSystem = operatingSystem
        self.distroID = distroID
        self.distroVersion = distroVersion
        self.desktopEnvironment = desktopEnvironment
        self.sessionType = sessionType
        self.capabilities = capabilities
        self.sharedMountStatus = sharedMountStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(
            Int.self,
            forKey: .protocolVersion
        )
        agentVersion = try container.decodeIfPresent(
            String.self,
            forKey: .agentVersion
        ) ?? "unknown"
        hostname = try container.decode(String.self, forKey: .hostname)
        ipAddresses = try container.decodeIfPresent(
            [String].self,
            forKey: .ipAddresses
        ) ?? []
        operatingSystem = try container.decodeIfPresent(
            String.self,
            forKey: .operatingSystem
        ) ?? "Linux"
        distroID = try container.decodeIfPresent(
            String.self,
            forKey: .distroID
        ) ?? "unknown"
        distroVersion = try container.decodeIfPresent(
            String.self,
            forKey: .distroVersion
        ) ?? "unknown"
        desktopEnvironment = try container.decodeIfPresent(
            GuestDesktopEnvironment.self,
            forKey: .desktopEnvironment
        ) ?? .other
        sessionType = try container.decodeIfPresent(
            GuestSessionType.self,
            forKey: .sessionType
        ) ?? .other
        capabilities = Set(
            try container.decodeIfPresent(
                [GuestAgentCapability].self,
                forKey: .capabilities
            ) ?? []
        )
        if let status = try container.decodeIfPresent(
            GuestSharedMountStatus.self,
            forKey: .sharedMountStatus
        ) {
            sharedMountStatus = status
        } else {
            let path = try container.decodeIfPresent(
                [String].self,
                forKey: .sharedDirectories
            )?.first
            sharedMountStatus = GuestSharedMountStatus(
                state: path == nil ? .unmounted : .mounted,
                message: path
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(agentVersion, forKey: .agentVersion)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(ipAddresses, forKey: .ipAddresses)
        try container.encode(operatingSystem, forKey: .operatingSystem)
        try container.encode(distroID, forKey: .distroID)
        try container.encode(distroVersion, forKey: .distroVersion)
        try container.encode(desktopEnvironment, forKey: .desktopEnvironment)
        try container.encode(sessionType, forKey: .sessionType)
        try container.encode(
            capabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .capabilities
        )
        try container.encode(sharedMountStatus, forKey: .sharedMountStatus)
    }
}

public struct GuestAgentFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum GuestAgentResponse: Equatable, Sendable {
    case hello(protocolVersion: Int)
    case status(GuestAgentStatus)
    case accepted
    case clipboard(text: String)
    case failure(GuestAgentFailure)
}

extension GuestAgentResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case status
        case text
        case code
        case message
        case hello
        case accepted
        case failure
    }

    private enum ResponseType: String, Codable {
        case hello
        case status
        case accepted
        case clipboard
        case failure
    }

    private struct LegacyHello: Decodable {
        let protocolVersion: Int
    }

    private struct LegacyFailure: Decodable {
        let message: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(
            ResponseType.self,
            forKey: .type
        ) {
            switch type {
            case .hello:
                self = .hello(
                    protocolVersion: try container.decode(
                        Int.self,
                        forKey: .protocolVersion
                    )
                )
            case .status:
                if container.contains(.status) {
                    self = .status(
                        try container.decode(
                            GuestAgentStatus.self,
                            forKey: .status
                        )
                    )
                } else {
                    self = .status(try GuestAgentStatus(from: decoder))
                }
            case .accepted:
                self = .accepted
            case .clipboard:
                let text = try container.decode(String.self, forKey: .text)
                guard text.utf8.count
                        <= GuestAgentProtocol.maximumClipboardSize else {
                    throw GuestAgentProtocolError.clipboardTooLarge
                }
                self = .clipboard(text: text)
            case .failure:
                self = .failure(
                    GuestAgentFailure(
                        code: try container.decodeIfPresent(
                            String.self,
                            forKey: .code
                        ) ?? "guestError",
                        message: try container.decode(
                            String.self,
                            forKey: .message
                        )
                    )
                )
            }
        } else if let hello = try container.decodeIfPresent(
            LegacyHello.self,
            forKey: .hello
        ) {
            self = .hello(protocolVersion: hello.protocolVersion)
        } else if container.contains(.status) {
            self = .status(
                try container.decode(GuestAgentStatus.self, forKey: .status)
            )
        } else if container.contains(.accepted) {
            self = .accepted
        } else if let failure = try container.decodeIfPresent(
            LegacyFailure.self,
            forKey: .failure
        ) {
            self = .failure(
                GuestAgentFailure(
                    code: "legacyFailure",
                    message: failure.message
                )
            )
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown guest-agent response."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let protocolVersion):
            try container.encode(ResponseType.hello, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case .status(let status):
            try container.encode(ResponseType.status, forKey: .type)
            try container.encode(status, forKey: .status)
        case .accepted:
            try container.encode(ResponseType.accepted, forKey: .type)
        case .clipboard(let text):
            guard text.utf8.count <= GuestAgentProtocol.maximumClipboardSize else {
                throw GuestAgentProtocolError.clipboardTooLarge
            }
            try container.encode(ResponseType.clipboard, forKey: .type)
            try container.encode(text, forKey: .text)
        case .failure(let failure):
            try container.encode(ResponseType.failure, forKey: .type)
            try container.encode(failure.code, forKey: .code)
            try container.encode(failure.message, forKey: .message)
        }
    }
}

public struct GuestAgentRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String?
    public let request: GuestAgentRequest

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case request
    }

    public init(
        protocolVersion: Int = GuestAgentProtocol.currentVersion,
        requestID: String = UUID().uuidString,
        request: GuestAgentRequest
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.request = request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.request) {
            protocolVersion = try container.decode(
                Int.self,
                forKey: .protocolVersion
            )
            requestID = try container.decodeIfPresent(
                String.self,
                forKey: .requestID
            )
            request = try container.decode(
                GuestAgentRequest.self,
                forKey: .request
            )
        } else {
            request = try GuestAgentRequest(from: decoder)
            requestID = nil
            if case .hello(let version) = request {
                protocolVersion = version
            } else {
                protocolVersion = 1
            }
        }
    }
}

public struct GuestAgentResponseEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String?
    public let response: GuestAgentResponse

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case response
    }

    public init(
        protocolVersion: Int = GuestAgentProtocol.currentVersion,
        requestID: String?,
        response: GuestAgentResponse
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.response = response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.response) {
            protocolVersion = try container.decode(
                Int.self,
                forKey: .protocolVersion
            )
            requestID = try container.decodeIfPresent(
                String.self,
                forKey: .requestID
            )
            response = try container.decode(
                GuestAgentResponse.self,
                forKey: .response
            )
        } else {
            response = try GuestAgentResponse(from: decoder)
            requestID = nil
            switch response {
            case .hello(let version):
                protocolVersion = version
            case .status(let status):
                protocolVersion = status.protocolVersion
            case .accepted, .clipboard, .failure:
                protocolVersion = 1
            }
        }
    }
}

public enum GuestDisplaySize {
    public static func isValid(width: Int, height: Int) -> Bool {
        (640...16_384).contains(width)
            && (480...16_384).contains(height)
    }
}

public enum GuestAgentFrameCodec {
    public static let maximumPayloadSize = 2 * 1_024 * 1_024

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
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
        do {
            return try JSONDecoder().decode(T.self, from: frame.dropFirst(4))
        } catch let error as GuestAgentProtocolError {
            throw error
        } catch {
            throw GuestAgentProtocolError.invalidMessage(
                error.localizedDescription
            )
        }
    }
}

public enum GuestAgentProtocolError: LocalizedError, Equatable {
    case payloadTooLarge
    case clipboardTooLarge
    case incompleteFrame
    case invalidDisplaySize
    case invalidMessage(String)
    case incompatibleVersion(Int)
    case mismatchedRequestID

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "The guest-agent message exceeds the size limit."
        case .clipboardTooLarge:
            "Clipboard text exceeds the 1 MiB Guest Tools limit."
        case .incompleteFrame:
            "The guest-agent message is incomplete."
        case .invalidDisplaySize:
            "The requested guest display size is outside the safe range."
        case .invalidMessage(let message):
            "The guest-agent message is invalid: \(message)"
        case .incompatibleVersion(let version):
            "Guest Tools protocol version \(version) is not supported."
        case .mismatchedRequestID:
            "Guest Tools returned a response for a different request."
        }
    }
}
