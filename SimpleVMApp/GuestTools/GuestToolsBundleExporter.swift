import Foundation
import SimpleVMCore

struct GuestToolsBundleExporter: Sendable {
    static let archiveName = "simplevm-guest-tools.tar.gz"
    static let manualInstallCommand =
        "tar -xzf simplevm-guest-tools.tar.gz && cd GuestTools && ./install.sh --with-wayland-clipboard --with-x11-agent"
    static func sharedInstallCommand(
        backend: VirtualizationBackendKind
    ) -> String {
        let mountCommand: String
        switch backend {
        case .appleVirtualization:
            mountCommand =
                "sudo mount -t virtiofs share /mnt/simplevm-share"
        case .qemu:
            mountCommand =
                "sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576 share /mnt/simplevm-share"
        }
        return [
            "sudo mkdir -p /mnt/simplevm-share",
            "(mountpoint -q /mnt/simplevm-share || \(mountCommand))",
            "rm -rf \"$HOME/simplevm-guest-tools\"",
            "mkdir -p \"$HOME/simplevm-guest-tools\"",
            "tar -xzf /mnt/simplevm-share/simplevm-guest-tools.tar.gz -C \"$HOME/simplevm-guest-tools\"",
            "cd \"$HOME/simplevm-guest-tools/GuestTools\"",
            "./install.sh --with-wayland-clipboard --with-x11-agent"
        ].joined(separator: " && ")
    }

    private let sourceURL: URL

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.resourceURL else {
            throw GuestToolsBundleError.missingResources
        }
        let sourceURL = resourceURL.appending(
            path: "GuestTools",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw GuestToolsBundleError.missingResources
        }
        self.sourceURL = sourceURL
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func export(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = destinationURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentURL.path) else {
            throw GuestToolsBundleError.destinationUnavailable
        }
        let temporaryURL = parentURL.appending(
            path: ".\(Self.archiveName).\(UUID().uuidString).tmp"
        )
        let tarURL = temporaryURL.appendingPathExtension("tar")
        defer {
            try? fileManager.removeItem(at: tarURL)
            try? fileManager.removeItem(at: temporaryURL)
        }

        let tarProcess = Process()
        tarProcess.executableURL = URL(filePath: "/usr/bin/tar")
        tarProcess.arguments = [
            "-cf",
            tarURL.path,
            "--uid",
            "0",
            "--gid",
            "0",
            "--uname",
            "root",
            "--gname",
            "root",
            "-C",
            sourceURL.deletingLastPathComponent().path,
            sourceURL.lastPathComponent
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        tarProcess.environment = environment
        try run(tarProcess, fallbackError: "tar exited with an error")

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil
        ) else {
            throw GuestToolsBundleError.destinationUnavailable
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }
        let gzipProcess = Process()
        gzipProcess.executableURL = URL(filePath: "/usr/bin/gzip")
        gzipProcess.arguments = ["-n", "-c", tarURL.path]
        gzipProcess.standardOutput = output
        try run(gzipProcess, fallbackError: "gzip exited with an error")
        try output.close()

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func run(
        _ process: Process,
        fallbackError: String
    ) throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestToolsBundleError.archiveFailed(
                message?.isEmpty == false ? message! : fallbackError
            )
        }
    }

    func copyToSharedDirectory(_ directoryURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GuestToolsBundleError.destinationUnavailable
        }
        let destinationURL = directoryURL.appending(path: Self.archiveName)
        try export(to: destinationURL)
        return destinationURL
    }
}

enum GuestToolsBundleError: LocalizedError, Equatable {
    case missingResources
    case destinationUnavailable
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingResources:
            "The SimpleVM Guest Tools resources are missing from this build."
        case .destinationUnavailable:
            "The selected Guest Tools destination is unavailable."
        case .archiveFailed(let message):
            "Could not create the Guest Tools bundle: \(message)"
        }
    }
}
