import Foundation

public enum GuestArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64

    public var displayName: String {
        switch self {
        case .arm64:
            "ARM64"
        case .x86_64:
            "x86_64"
        }
    }
}

public enum VirtualizationBackendKind: String, Codable, Sendable {
    case appleVirtualization
    case qemu
}

