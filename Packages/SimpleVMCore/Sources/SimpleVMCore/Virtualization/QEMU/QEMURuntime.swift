import Foundation

public enum QEMUDisplayBackend: Equatable, Sendable {
    case vnc
    case spiceGL(resourceDirectoryURL: URL)
}

public enum QEMUAcceleration: Equatable, Sendable {
    case tcg
    case hvf
}

public enum QEMUImageFormat: String, Equatable, Sendable {
    case raw
    case qcow2
}

public struct QEMURuntime: Equatable, Sendable {
    public let architecture: GuestArchitecture
    public let systemExecutableURL: URL
    public let imageExecutableURL: URL?
    public let firmwareCodeURL: URL
    public let firmwareCodeFormat: QEMUImageFormat
    public let firmwareVariablesTemplateURL: URL
    public let firmwareVariablesFormat: QEMUImageFormat
    public let displayBackend: QEMUDisplayBackend
    public let acceleration: QEMUAcceleration
    public let softwareTPMExecutableURL: URL?

    public init(
        architecture: GuestArchitecture = .x86_64,
        systemExecutableURL: URL,
        imageExecutableURL: URL?,
        firmwareCodeURL: URL,
        firmwareCodeFormat: QEMUImageFormat = .raw,
        firmwareVariablesTemplateURL: URL,
        firmwareVariablesFormat: QEMUImageFormat = .raw,
        displayBackend: QEMUDisplayBackend = .vnc,
        acceleration: QEMUAcceleration = .tcg,
        softwareTPMExecutableURL: URL? = nil
    ) {
        self.architecture = architecture
        self.systemExecutableURL = systemExecutableURL
        self.imageExecutableURL = imageExecutableURL
        self.firmwareCodeURL = firmwareCodeURL
        self.firmwareCodeFormat = firmwareCodeFormat
        self.firmwareVariablesTemplateURL = firmwareVariablesTemplateURL
        self.firmwareVariablesFormat = firmwareVariablesFormat
        self.displayBackend = displayBackend
        self.acceleration = acceleration
        self.softwareTPMExecutableURL = softwareTPMExecutableURL
    }
}

public enum QEMURuntimeDiscovery {
    public static func discover(
        for operatingSystem: GuestOperatingSystem = .linux,
        architecture: GuestArchitecture = .x86_64,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.resourceURL,
        helperDirectoryURL: URL? = nil,
        utmURL: URL = URL(filePath: "/Applications/UTM.app"),
        fileManager: FileManager = .default
    ) throws -> QEMURuntime {
        switch (operatingSystem, architecture) {
        case (.windows, .arm64):
            return try discoverUTMWindowsARM64(
                helperDirectoryURL: resolvedHelperDirectory(
                    helperDirectoryURL
                ),
                utmURL: utmURL,
                fileManager: fileManager
            )
        case (.linux, .x86_64):
            if let runtime = discoverUTMLinuxX86(
                helperDirectoryURL: resolvedHelperDirectory(
                    helperDirectoryURL
                ),
                utmURL: utmURL,
                environment: environment,
                bundleURL: bundleURL,
                fileManager: fileManager
            ) {
                return runtime
            }
            return try discoverPrefixLinuxX86(
                environment: environment,
                bundleURL: bundleURL,
                fileManager: fileManager
            )
        case (.linux, .arm64), (.windows, .x86_64):
            throw QEMURuntimeError.unsupportedGuest(
                operatingSystem: operatingSystem,
                architecture: architecture
            )
        }
    }

    private static func discoverUTMWindowsARM64(
        helperDirectoryURL: URL,
        utmURL: URL,
        fileManager: FileManager
    ) throws -> QEMURuntime {
        let frameworkURL = utmURL.appending(
            path:
                "Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
        )
        let resourcesURL = utmURL.appending(
            path: "Contents/Resources/qemu",
            directoryHint: .isDirectory
        )
        let systemURL = helperDirectoryURL.appending(
            path: "UTMQEMUARM64Launcher"
        )
        let swtpmURL = helperDirectoryURL.appending(path: "UTMSWTPMLauncher")
        let codeURL = resourcesURL.appending(
            path: "edk2-aarch64-secure-code.fd"
        )
        let variablesURL = resourcesURL.appending(
            path: "edk2-arm-secure-vars.fd"
        )
        guard fileManager.isExecutableFile(atPath: systemURL.path),
              fileManager.isExecutableFile(atPath: swtpmURL.path),
              fileManager.fileExists(atPath: frameworkURL.path),
              fileManager.fileExists(atPath: codeURL.path),
              fileManager.fileExists(atPath: variablesURL.path),
              try imageFormat(at: variablesURL) == .qcow2,
              try qcow2VirtualSize(at: variablesURL)
                == 64 * 1_024 * 1_024 else {
            throw QEMURuntimeError.windowsRuntimeIncomplete
        }
        return QEMURuntime(
            architecture: .arm64,
            systemExecutableURL: systemURL,
            imageExecutableURL: nil,
            firmwareCodeURL: codeURL,
            firmwareCodeFormat: .raw,
            firmwareVariablesTemplateURL: variablesURL,
            firmwareVariablesFormat: try imageFormat(at: variablesURL),
            displayBackend: .spiceGL(resourceDirectoryURL: resourcesURL),
            acceleration: .hvf,
            softwareTPMExecutableURL: swtpmURL
        )
    }

    private static func discoverUTMLinuxX86(
        helperDirectoryURL: URL,
        utmURL: URL,
        environment: [String: String],
        bundleURL: URL?,
        fileManager: FileManager
    ) -> QEMURuntime? {
        let frameworkURL = utmURL.appending(
            path:
                "Contents/Frameworks/qemu-x86_64-softmmu.framework/qemu-x86_64-softmmu"
        )
        let resourcesURL = utmURL.appending(
            path: "Contents/Resources/qemu",
            directoryHint: .isDirectory
        )
        let systemURL = helperDirectoryURL.appending(path: "UTMQEMULauncher")
        let codeURL = resourcesURL.appending(path: "edk2-x86_64-code.fd")
        let variablesURL = resourcesURL.appending(path: "edk2-i386-vars.fd")
        guard fileManager.isExecutableFile(atPath: systemURL.path),
              fileManager.fileExists(atPath: frameworkURL.path),
              fileManager.fileExists(atPath: codeURL.path),
              fileManager.fileExists(atPath: variablesURL.path),
              let variablesFormat = try? imageFormat(at: variablesURL) else {
            return nil
        }
        return QEMURuntime(
            architecture: .x86_64,
            systemExecutableURL: systemURL,
            imageExecutableURL: discoverImageExecutable(
                environment: environment,
                bundleURL: bundleURL,
                fileManager: fileManager
            ),
            firmwareCodeURL: codeURL,
            firmwareCodeFormat: .raw,
            firmwareVariablesTemplateURL: variablesURL,
            firmwareVariablesFormat: variablesFormat,
            displayBackend: .spiceGL(resourceDirectoryURL: resourcesURL),
            acceleration: .tcg
        )
    }

    private static func discoverPrefixLinuxX86(
        environment: [String: String],
        bundleURL: URL?,
        fileManager: FileManager
    ) throws -> QEMURuntime {
        for prefix in candidatePrefixes(
            environment: environment,
            bundleURL: bundleURL
        ) {
            let binURL = prefix.appending(path: "bin", directoryHint: .isDirectory)
            let shareURL = prefix.appending(
                path: "share/qemu",
                directoryHint: .isDirectory
            )
            let variablesURL = shareURL.appending(path: "edk2-i386-vars.fd")
            let runtime = QEMURuntime(
                architecture: .x86_64,
                systemExecutableURL: binURL.appending(
                    path: "qemu-system-x86_64"
                ),
                imageExecutableURL: binURL.appending(path: "qemu-img"),
                firmwareCodeURL: shareURL.appending(
                    path: "edk2-x86_64-code.fd"
                ),
                firmwareVariablesTemplateURL: variablesURL,
                firmwareVariablesFormat:
                    (try? imageFormat(at: variablesURL)) ?? .raw
            )
            if isValidPrefixRuntime(runtime, fileManager: fileManager) {
                return runtime
            }
        }
        throw QEMURuntimeError.notFound
    }

    private static func discoverImageExecutable(
        environment: [String: String],
        bundleURL: URL?,
        fileManager: FileManager
    ) -> URL? {
        for prefix in candidatePrefixes(
            environment: environment,
            bundleURL: bundleURL
        ) {
            let url = prefix.appending(path: "bin/qemu-img")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func resolvedHelperDirectory(_ configured: URL?) -> URL {
        configured ?? Bundle.main.bundleURL.appending(
            path: "Contents/Helpers",
            directoryHint: .isDirectory
        )
    }

    private static func candidatePrefixes(
        environment: [String: String],
        bundleURL: URL?
    ) -> [URL] {
        var prefixes: [URL] = []
        if let bundleURL {
            prefixes.append(
                bundleURL.appending(
                    path: "QEMU",
                    directoryHint: .isDirectory
                )
            )
        }
        if let configured = environment["SIMPLEVM_QEMU_PREFIX"] {
            prefixes.append(URL(filePath: configured))
        }
        prefixes.append(contentsOf: [
            URL(filePath: "/opt/homebrew/opt/qemu"),
            URL(filePath: "/usr/local/opt/qemu"),
            URL(filePath: "/opt/local")
        ])
        return prefixes
    }

    private static func isValidPrefixRuntime(
        _ runtime: QEMURuntime,
        fileManager: FileManager
    ) -> Bool {
        fileManager.isExecutableFile(
            atPath: runtime.systemExecutableURL.path
        )
            && runtime.imageExecutableURL.map {
                fileManager.isExecutableFile(atPath: $0.path)
            } == true
            && fileManager.fileExists(atPath: runtime.firmwareCodeURL.path)
            && fileManager.fileExists(
                atPath: runtime.firmwareVariablesTemplateURL.path
            )
    }

    public static func imageFormat(at url: URL) throws -> QEMUImageFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        return magic == Data([0x51, 0x46, 0x49, 0xfb]) ? .qcow2 : .raw
    }

    public static func qcow2VirtualSize(at url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 32) ?? Data()
        guard header.count == 32,
              header.prefix(4) == Data([0x51, 0x46, 0x49, 0xfb]) else {
            throw QEMURuntimeError.invalidFirmwareVariables
        }
        return header[24..<32].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}

public enum QEMURuntimeError: LocalizedError, Equatable {
    case notFound
    case windowsRuntimeIncomplete
    case invalidFirmwareVariables
    case unsupportedGuest(
        operatingSystem: GuestOperatingSystem,
        architecture: GuestArchitecture
    )

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "QEMU was not found. Install UTM or configure SIMPLEVM_QEMU_PREFIX."
        case .windowsRuntimeIncomplete:
            "Windows 11 ARM64 requires UTM’s ARM QEMU, secure firmware, SPICE, and TPM runtime helpers."
        case .invalidFirmwareVariables:
            "The ARM UEFI variable store is not a valid 64 MiB QCOW2 image."
        case .unsupportedGuest(let operatingSystem, let architecture):
            "QEMU does not support \(operatingSystem.displayName) \(architecture.displayName) in SimpleVM."
        }
    }
}
