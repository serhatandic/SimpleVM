import Darwin
import Foundation

public actor SoftwareTPMProcessController {
    private var process: Process?
    private var logHandle: FileHandle?
    private var socketURL: URL?

    public init() {}

    public func start(
        configuration: QEMUSoftwareTPMConfiguration
    ) async throws {
        guard process == nil else {
            throw SoftwareTPMProcessError.alreadyRunning
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: configuration.stateURL.path) {
            guard fileManager.createFile(
                atPath: configuration.stateURL.path,
                contents: nil
            ) else {
                throw SoftwareTPMProcessError.stateUnavailable
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configuration.stateURL.path
        )
        if fileManager.fileExists(atPath: configuration.socketURL.path) {
            try fileManager.removeItem(at: configuration.socketURL)
        }
        fileManager.createFile(
            atPath: configuration.logURL.path,
            contents: nil
        )
        let logHandle = try FileHandle(forWritingTo: configuration.logURL)
        let process = Process()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.socketURL
            .deletingLastPathComponent()
        process.arguments = [
            "--ctrl",
            "type=unixio,path=\(configuration.socketURL.path),terminate",
            "--tpmstate",
            "backend-uri=file://\(configuration.stateURL.path)",
            "--tpm2"
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw error
        }
        self.process = process
        self.logHandle = logHandle
        socketURL = configuration.socketURL

        do {
            for _ in 0..<150 {
                if !process.isRunning {
                    throw SoftwareTPMProcessError.startupFailed
                }
                if fileManager.fileExists(
                    atPath: configuration.socketURL.path
                ) {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw SoftwareTPMProcessError.startupTimedOut
        } catch {
            await forceStop()
            throw error
        }
    }

    public func stop() async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            for _ in 0..<50 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        await waitForExit(process)
        clear()
    }

    public func forceStop() async {
        guard let process else { return }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        await waitForExit(process)
        clear()
    }

    private func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            Task.detached {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func clear() {
        try? logHandle?.close()
        logHandle = nil
        process = nil
        if let socketURL {
            try? FileManager.default.removeItem(at: socketURL)
        }
        socketURL = nil
    }
}

public enum SoftwareTPMProcessError: LocalizedError, Equatable {
    case alreadyRunning
    case stateUnavailable
    case startupFailed
    case startupTimedOut

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The software TPM is already running."
        case .stateUnavailable:
            "The software TPM state file could not be created."
        case .startupFailed:
            "The software TPM exited before creating its control socket."
        case .startupTimedOut:
            "The software TPM did not become ready in time."
        }
    }
}
