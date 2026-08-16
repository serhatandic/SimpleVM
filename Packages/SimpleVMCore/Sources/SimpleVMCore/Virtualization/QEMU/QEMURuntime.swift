import Foundation

public enum QEMUDisplayBackend: Equatable, Sendable {
    case vnc
    case spiceGL(resourceDirectoryURL: URL)
}

public struct QEMURuntime: Equatable, Sendable {
    public let systemExecutableURL: URL
    public let imageExecutableURL: URL
    public let firmwareCodeURL: URL
    public let firmwareVariablesTemplateURL: URL
    public let displayBackend: QEMUDisplayBackend

    public init(
        systemExecutableURL: URL,
        imageExecutableURL: URL,
        firmwareCodeURL: URL,
        firmwareVariablesTemplateURL: URL,
        displayBackend: QEMUDisplayBackend = .vnc
    ) {
        self.systemExecutableURL = systemExecutableURL
        self.imageExecutableURL = imageExecutableURL
        self.firmwareCodeURL = firmwareCodeURL
        self.firmwareVariablesTemplateURL = firmwareVariablesTemplateURL
        self.displayBackend = displayBackend
    }
}

public enum QEMURuntimeDiscovery {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) throws -> QEMURuntime {
        let prefixes = candidatePrefixes(
            environment: environment,
            bundleURL: bundleURL
        )
        for prefix in prefixes {
            let binURL = prefix.appending(path: "bin", directoryHint: .isDirectory)
            let shareURL = prefix.appending(
                path: "share/qemu",
                directoryHint: .isDirectory
            )
            let runtime = QEMURuntime(
                systemExecutableURL: binURL.appending(
                    path: "qemu-system-x86_64"
                ),
                imageExecutableURL: binURL.appending(path: "qemu-img"),
                firmwareCodeURL: shareURL.appending(
                    path: "edk2-x86_64-code.fd"
                ),
                firmwareVariablesTemplateURL: shareURL.appending(
                    path: "edk2-i386-vars.fd"
                )
            )
            if isValid(runtime, fileManager: fileManager) {
                return runtime
            }
        }
        throw QEMURuntimeError.notFound
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

    private static func isValid(
        _ runtime: QEMURuntime,
        fileManager: FileManager
    ) -> Bool {
        fileManager.isExecutableFile(
            atPath: runtime.systemExecutableURL.path
        )
            && fileManager.isExecutableFile(
                atPath: runtime.imageExecutableURL.path
            )
            && fileManager.fileExists(atPath: runtime.firmwareCodeURL.path)
            && fileManager.fileExists(
                atPath: runtime.firmwareVariablesTemplateURL.path
            )
    }
}

public enum QEMURuntimeError: LocalizedError, Equatable {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "QEMU was not found. Install QEMU or configure SIMPLEVM_QEMU_PREFIX."
        }
    }
}
