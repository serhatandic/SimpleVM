import Foundation

public enum ISOArchitectureDetection: Equatable, Sendable {
    case architecture(GuestArchitecture)
    case ambiguous
    case unknown
}

public enum ISOArchitectureDetector {
    private static let arm64Marker = Data("BOOTAA64.EFI".utf8)
    private static let x86Marker = Data("BOOTX64.EFI".utf8)

    public static func detect(
        at url: URL,
        chunkSize: Int = 2 * 1_024 * 1_024
    ) throws -> ISOArchitectureDetection {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let overlapSize = max(arm64Marker.count, x86Marker.count) - 1
        var overlap = Data()
        var foundARM64 = false
        var foundX86 = false

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let searchable = overlap + chunk
            foundARM64 = foundARM64 || searchable.range(of: arm64Marker) != nil
            foundX86 = foundX86 || searchable.range(of: x86Marker) != nil

            if foundARM64 && foundX86 {
                return .ambiguous
            }

            overlap = searchable.suffix(overlapSize)
        }

        switch (foundARM64, foundX86) {
        case (true, false):
            return .architecture(.arm64)
        case (false, true):
            return .architecture(.x86_64)
        case (true, true):
            return .ambiguous
        case (false, false):
            return .unknown
        }
    }
}

