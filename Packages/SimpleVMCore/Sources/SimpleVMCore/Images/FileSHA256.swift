import CryptoKit
import Foundation

public enum FileSHA256 {
    public static func digest(
        of url: URL,
        chunkSize: Int = 4 * 1_024 * 1_024
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }

        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}

