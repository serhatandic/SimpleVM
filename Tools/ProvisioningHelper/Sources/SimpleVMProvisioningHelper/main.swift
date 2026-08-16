import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage

@main
struct SimpleVMProvisioningHelper {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            throw HelperError.invalidArguments
        }
        if arguments[1] == "rootfs" {
            try await provisionRootFS(arguments)
            return
        }
        if arguments[1] == "kernel" {
            try extractKernel(arguments)
            return
        }
        guard arguments.count == 7, arguments[1] == "pull",
              let capacity = UInt64(arguments[5]) else {
            throw HelperError.invalidArguments
        }

        let reference = arguments[2]
        let contentStoreURL = URL(filePath: arguments[3])
        let diskURL = URL(filePath: arguments[4])
        let architecture = arguments[6] == "arm64" ? "arm64" : "amd64"
        let platform = Platform(
            arch: architecture,
            os: "linux",
            variant: architecture == "arm64" ? "v8" : nil
        )
        let client = try RegistryClient(reference: reference)
        let parsedReference = try Reference.parse(reference)
        guard let tag = parsedReference.tag ?? parsedReference.digest else {
            throw HelperError.missingTag
        }
        let root = try await client.resolve(
            name: parsedReference.path,
            tag: tag
        )
        let descriptor: Descriptor
        if root.mediaType == MediaTypes.index
            || root.mediaType == MediaTypes.dockerManifestList {
            let index: ContainerizationOCI.Index = try await client.fetch(
                name: parsedReference.path,
                descriptor: root
            )
            guard let match = index.manifests.first(where: {
                $0.platform == platform
            }) else {
                throw HelperError.platformUnavailable
            }
            descriptor = match
        } else {
            descriptor = root
        }
        let manifest: Manifest = try await client.fetch(
            name: parsedReference.path,
            descriptor: descriptor
        )
        try FileManager.default.createDirectory(
            at: contentStoreURL,
            withIntermediateDirectories: true
        )
        let formatter = try EXT4.Formatter(
            FilePath(diskURL.path),
            minDiskSize: capacity,
            journal: .default
        )
        do {
            for layer in manifest.layers {
                let layerURL = contentStoreURL.appending(
                    path: layer.digest.replacingOccurrences(of: ":", with: "-")
                )
                _ = try await client.fetchBlob(
                    name: parsedReference.path,
                    descriptor: layer,
                    into: layerURL,
                    progress: nil
                )
                try await formatter.unpack(
                    source: layerURL,
                    format: .paxRestricted,
                    compression: try filter(for: layer.mediaType)
                )
                try? FileManager.default.removeItem(at: layerURL)
            }
            try formatter.close()
        } catch {
            try? formatter.close()
            try? FileManager.default.removeItem(at: diskURL)
            throw error
        }
    }

    private static func extractKernel(_ arguments: [String]) throws {
        guard arguments.count == 4 else {
            throw HelperError.invalidArguments
        }
        let source = try Data(contentsOf: URL(filePath: arguments[2]))
        guard source.count >= 16, source[4..<8] == Data("zimg".utf8) else {
            throw HelperError.unsupportedKernel
        }
        let offset = Int(readLittleEndianUInt32(source, at: 8))
        let size = Int(readLittleEndianUInt32(source, at: 12))
        guard offset >= 0, size > 0, offset + size <= source.count else {
            throw HelperError.unsupportedKernel
        }
        let outputURL = URL(filePath: arguments[3])
        let compressedURL = outputURL.appendingPathExtension("gz")
        try source[offset..<(offset + size)].write(
            to: compressedURL,
            options: .atomic
        )
        defer { try? FileManager.default.removeItem(at: compressedURL) }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-dc", compressedURL.path]
        process.standardOutput = outputHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperError.unsupportedKernel
        }
        let handle = try FileHandle(forReadingFrom: outputURL)
        try handle.seek(toOffset: 0x38)
        let magic = try handle.read(upToCount: 4)
        try handle.close()
        guard magic == Data("ARMd".utf8) else {
            throw HelperError.unsupportedKernel
        }
    }

    private static func readLittleEndianUInt32(
        _ data: Data,
        at offset: Int
    ) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    private static func provisionRootFS(_ arguments: [String]) async throws {
        guard arguments.count == 6,
              let capacity = UInt64(arguments[4]) else {
            throw HelperError.invalidArguments
        }
        let filter: ContainerizationArchive.Filter = switch arguments[5] {
        case "none": .none
        case "gzip": .gzip
        case "zstd": .zstd
        default: throw HelperError.unsupportedLayer
        }
        let formatter = try EXT4.Formatter(
            FilePath(arguments[3]),
            minDiskSize: capacity,
            journal: .default
        )
        do {
            try await formatter.unpack(
                source: URL(filePath: arguments[2]),
                format: .paxRestricted,
                compression: filter
            )
            try formatter.close()
        } catch {
            try? formatter.close()
            try? FileManager.default.removeItem(atPath: arguments[3])
            throw error
        }
    }

    private static func filter(
        for mediaType: String
    ) throws -> ContainerizationArchive.Filter {
        switch mediaType {
        case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
            .none
        case MediaTypes.imageLayerGzip, MediaTypes.dockerImageLayerGzip:
            .gzip
        case MediaTypes.imageLayerZstd, MediaTypes.dockerImageLayerZstd:
            .zstd
        default:
            throw HelperError.unsupportedLayer
        }
    }
}

private enum HelperError: LocalizedError {
    case invalidArguments
    case missingTag
    case platformUnavailable
    case unsupportedLayer
    case unsupportedKernel

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: SimpleVMProvisioningHelper pull <reference> <store> <disk> <capacity> <arm64|x86_64> | rootfs <archive> <disk> <capacity> <none|gzip|zstd>"
        case .missingTag:
            "OCI reference must include a tag or digest."
        case .platformUnavailable:
            "OCI image does not provide the requested platform."
        case .unsupportedLayer:
            "OCI image contains an unsupported layer."
        case .unsupportedKernel:
            "The Linux kernel is not a supported ARM64 EFI zboot image."
        }
    }
}
