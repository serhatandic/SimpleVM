import Foundation

public enum SparseDiskCreator {
    public static let sectorSize: UInt64 = 512

    public static func alignedCapacity(_ requestedBytes: UInt64) -> UInt64 {
        let remainder = requestedBytes % sectorSize
        guard remainder != 0 else {
            return requestedBytes
        }
        return requestedBytes + sectorSize - remainder
    }

    @discardableResult
    public static func create(
        at url: URL,
        capacityBytes: UInt64,
        fileManager: FileManager = .default
    ) throws -> UInt64 {
        let alignedCapacity = alignedCapacity(capacityBytes)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.truncate(atOffset: alignedCapacity)
        return alignedCapacity
    }
}

