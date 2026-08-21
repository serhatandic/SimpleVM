import Darwin
import Foundation

public enum QEMUStopResult: Equatable, Sendable {
    case stopped
    case timedOut
    case requestFailed(String)
}

public actor QEMUProcessController {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    private var process: Process?
    private var logHandle: FileHandle?
    private var expectsTermination = false
    private var qmpSocketURL: URL?
    private(set) public var state: State = .stopped
    private let stateHandler: @Sendable (State) -> Void

    public init(
        stateHandler: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.stateHandler = stateHandler
    }

    public func start(configuration: QEMUConfiguration) throws {
        guard process == nil else {
            throw QEMUProcessError.alreadyRunning
        }
        transition(to: .starting)
        expectsTermination = false

        FileManager.default.createFile(
            atPath: configuration.logURL.path,
            contents: nil
        )
        let logHandle = try FileHandle(forWritingTo: configuration.logURL)
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.processTerminated(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.logHandle = logHandle
            qmpSocketURL = configuration.qmpSocketURL
            transition(to: .running)
        } catch {
            try? logHandle.close()
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    public func stop(
        gracePeriod: Duration = .seconds(300)
    ) async -> QEMUStopResult {
        guard let process else {
            return .stopped
        }
        transition(to: .stopping)
        expectsTermination = true
        guard let qmpSocketURL,
              FileManager.default.fileExists(atPath: qmpSocketURL.path) else {
            expectsTermination = false
            transition(to: .running)
            return .requestFailed("QEMU control is unavailable.")
        }
        do {
            try sendQMPCommand(
                #"{"execute":"system_powerdown"}"#,
                socketURL: qmpSocketURL
            )
        } catch {
            expectsTermination = false
            transition(to: .running)
            return .requestFailed(error.localizedDescription)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !process.isRunning else {
            return .timedOut
        }
        completeExpectedTermination(of: process)
        return .stopped
    }

    public func reset() throws {
        guard let qmpSocketURL,
              FileManager.default.fileExists(atPath: qmpSocketURL.path) else {
            throw QEMUProcessError.controlUnavailable
        }
        try sendQMPCommand(
            #"{"execute":"system_reset"}"#,
            socketURL: qmpSocketURL
        )
    }

    public func forceStop() async {
        guard let process else {
            return
        }
        transition(to: .stopping)
        expectsTermination = true
        kill(process.processIdentifier, SIGKILL)
        await withCheckedContinuation { continuation in
            Task.detached {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        completeExpectedTermination(of: process)
    }

    private func processTerminated(status: Int32) {
        guard process != nil else {
            return
        }
        let expected = expectsTermination || state == .stopping
        clearProcess()
        expectsTermination = false
        transition(
            to: expected || status == 0
                ? .stopped
                : .failed("QEMU exited with status \(status).")
        )
    }

    private func completeExpectedTermination(of completedProcess: Process) {
        guard process === completedProcess else {
            return
        }
        clearProcess()
        expectsTermination = false
        transition(to: .stopped)
    }

    private func clearProcess() {
        process = nil
        try? logHandle?.close()
        logHandle = nil
        qmpSocketURL = nil
    }

    private func transition(to state: State) {
        self.state = state
        stateHandler(state)
    }

    private func sendQMPCommand(
        _ command: String,
        socketURL: URL
    ) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
        else {
            throw QEMUProcessError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.enumerated() {
                bytes[index] = byte
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = try readQMPLine(descriptor: descriptor)
        try writeQMP(
            #"{"execute":"qmp_capabilities"}"#,
            descriptor: descriptor
        )
        _ = try readQMPLine(descriptor: descriptor)
        try writeQMP(command, descriptor: descriptor)
        _ = try readQMPLine(descriptor: descriptor)
    }

    private func writeQMP(_ command: String, descriptor: Int32) throws {
        let data = Data("\(command)\r\n".utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                offset += written
            }
        }
    }

    private func readQMPLine(descriptor: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < 1_024 * 1_024 {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            result.append(byte)
            if byte == 0x0a {
                return result
            }
        }
        throw QEMUProcessError.invalidQMPResponse
    }
}

public enum QEMUProcessError: LocalizedError, Equatable {
    case alreadyRunning
    case controlUnavailable
    case socketPathTooLong
    case invalidQMPResponse

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The QEMU machine is already running."
        case .controlUnavailable:
            "QEMU control is unavailable."
        case .socketPathTooLong:
            "The QEMU control socket path is too long."
        case .invalidQMPResponse:
            "QEMU returned an invalid control response."
        }
    }
}
