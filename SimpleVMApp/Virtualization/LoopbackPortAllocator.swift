import Darwin
import Foundation

enum LoopbackPortAllocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserved: Set<UInt16> = []

    static func allocate() async throws -> UInt16 {
        try lock.withLock {
            for port in UInt16(5_900)...UInt16(5_999) {
                if !reserved.contains(port), canBind(port: port) {
                    reserved.insert(port)
                    return port
                }
            }
            throw PortAllocatorError.missingPort
        }
    }

    static func release(_ port: UInt16) {
        _ = lock.withLock {
            reserved.remove(port)
        }
    }

    private static func canBind(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        } == 0
    }
}

final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else {
                return false
            }
            claimed = true
            return true
        }
    }
}

private enum PortAllocatorError: LocalizedError {
    case missingPort

    var errorDescription: String? {
        "macOS did not allocate a loopback port."
    }
}
