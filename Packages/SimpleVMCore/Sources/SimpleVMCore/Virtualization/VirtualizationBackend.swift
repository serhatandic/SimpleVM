import Foundation

public protocol VirtualizationBackend: Sendable {
    associatedtype RuntimeHandle

    func prepare(machine: Machine) async throws
    func validate(machine: Machine) async throws
}

