import Foundation

public struct ProvisioningHelperClient: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public static func bundled(
        bundleURL: URL = Bundle.main.bundleURL
    ) throws -> ProvisioningHelperClient {
        let executableURL = bundleURL.appending(
            path: "Contents/Helpers/SimpleVMProvisioningHelper"
        )
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw ProvisioningHelperError.notInstalled
        }
        return ProvisioningHelperClient(executableURL: executableURL)
    }

    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> ProvisioningHelperClient {
        if let configured = environment["SIMPLEVM_PROVISIONING_HELPER"] {
            let url = URL(filePath: configured)
            if fileManager.isExecutableFile(atPath: url.path) {
                return ProvisioningHelperClient(executableURL: url)
            }
        }
        if let bundled = try? bundled(bundleURL: bundleURL) {
            return bundled
        }

        let repositoryURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildURL = repositoryURL.appending(
            path: "Tools/ProvisioningHelper/.build"
        )
        let candidates = [
            buildURL.appending(path: "release/SimpleVMProvisioningHelper"),
            buildURL.appending(
                path: "arm64-apple-macosx/release/SimpleVMProvisioningHelper"
            ),
            buildURL.appending(
                path: "x86_64-apple-macosx/release/SimpleVMProvisioningHelper"
            )
        ]
        for url in candidates {
            if fileManager.isExecutableFile(atPath: url.path) {
                return ProvisioningHelperClient(executableURL: url)
            }
        }
        throw ProvisioningHelperError.notInstalled
    }

    public func provision(
        reference: String,
        contentStoreURL: URL,
        diskURL: URL,
        capacityBytes: UInt64,
        architecture: GuestArchitecture
    ) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "pull",
            reference,
            contentStoreURL.path,
            diskURL.path,
            String(capacityBytes),
            architecture.rawValue
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)
                ?? "OCI helper failed."
            throw ProvisioningHelperError.failed(message)
        }
    }

    public func provisionRootFS(
        archiveURL: URL,
        diskURL: URL,
        capacityBytes: UInt64,
        compression: String
    ) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "rootfs",
            archiveURL.path,
            diskURL.path,
            String(capacityBytes),
            compression
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw ProvisioningHelperError.failed(
                String(data: data, encoding: .utf8)
                    ?? "Provisioning helper failed."
            )
        }
    }

    public func extractKernel(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "kernel",
            sourceURL.path,
            destinationURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw ProvisioningHelperError.failed(
                String(data: data, encoding: .utf8)
                    ?? "Kernel extraction failed."
            )
        }
    }
}

public enum ProvisioningHelperError: LocalizedError, Equatable {
    case failed(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        case .notInstalled:
            "The SimpleVM provisioning helper is not installed."
        }
    }
}
