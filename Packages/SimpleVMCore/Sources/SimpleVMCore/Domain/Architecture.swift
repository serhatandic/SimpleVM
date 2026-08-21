import Foundation

public enum GuestOperatingSystem: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case linux
    case windows

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .linux:
            "Linux"
        case .windows:
            "Windows 11"
        }
    }
}

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

    public static func resolve(
        operatingSystem: GuestOperatingSystem,
        architecture: GuestArchitecture
    ) throws -> Self {
        switch (operatingSystem, architecture) {
        case (.linux, .arm64):
            .appleVirtualization
        case (.linux, .x86_64), (.windows, .arm64):
            .qemu
        case (.windows, .x86_64):
            throw GuestPlatformError.unsupported(
                operatingSystem: operatingSystem,
                architecture: architecture
            )
        }
    }
}

public enum GuestPlatformError: LocalizedError, Equatable {
    case unsupported(
        operatingSystem: GuestOperatingSystem,
        architecture: GuestArchitecture
    )

    public var errorDescription: String? {
        switch self {
        case .unsupported(let operatingSystem, let architecture):
            "\(operatingSystem.displayName) \(architecture.displayName) is not supported."
        }
    }
}
