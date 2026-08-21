import Foundation

public struct MachineSnapshot: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let diskRelativePath: String
    public let stateDirectoryRelativePath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        diskRelativePath: String,
        stateDirectoryRelativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.diskRelativePath = diskRelativePath
        self.stateDirectoryRelativePath = stateDirectoryRelativePath
    }
}
