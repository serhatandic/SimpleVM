import Darwin
import Foundation
import SimpleVMCore

final class TCPPortForwarder: @unchecked Sendable {
    private let forward: PortForward
    private let guestAddress: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var running = false

    init(forward: PortForward, guestAddress: String) {
        self.forward = forward
        self.guestAddress = guestAddress
    }

    func start() throws {
        try PortForwardValidator.validate(forward)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = forward.hostPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, listen(descriptor, 16) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        lock.withLock {
            listener = descriptor
            running = true
        }
        Task.detached { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let descriptor = lock.withLock {
            running = false
            let descriptor = listener
            listener = -1
            return descriptor
        }
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private func acceptLoop() {
        while lock.withLock({ running }) {
            let descriptor = lock.withLock { listener }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                continue
            }
            Task.detached { [weak self] in
                self?.bridge(client: client)
            }
        }
    }

    private func bridge(client: Int32) {
        let guest = socket(AF_INET, SOCK_STREAM, 0)
        guard guest >= 0 else {
            close(client)
            return
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = forward.guestPort.bigEndian
        guard inet_pton(AF_INET, guestAddress, &address.sin_addr) == 1 else {
            close(client)
            close(guest)
            return
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    guest,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            close(client)
            close(guest)
            return
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            Self.copy(from: client, to: guest)
            shutdown(guest, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            Self.copy(from: guest, to: client)
            shutdown(client, SHUT_WR)
            group.leave()
        }
        group.wait()
        close(client)
        close(guest)
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = recv(source, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    send(
                        destination,
                        $0.baseAddress!.advanced(by: offset),
                        count - offset,
                        0
                    )
                }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
