import Foundation
import Testing
@testable import SimpleVMCore

@Test
func loadsDistributionNeutralBundledCatalog() throws {
    let entries = try ImageCatalog.bundled()
    let entry = try #require(entries.first)

    #expect(entry.artifactKind == .installerISO)
    #expect(entry.architecture == .arm64)
    #expect(entry.remoteURL.scheme == "https")
    #expect(entry.sha256.count == 64)
}

@Test(arguments: [
    ("EFI/BOOT/BOOTAA64.EFI", ISOArchitectureDetection.architecture(.arm64)),
    ("EFI/BOOT/BOOTX64.EFI", ISOArchitectureDetection.architecture(.x86_64)),
    (
        "BOOTAA64.EFI and BOOTX64.EFI",
        ISOArchitectureDetection.ambiguous
    ),
    ("not bootable", ISOArchitectureDetection.unknown)
])
func detectsISOFallbackArchitecture(
    contents: String,
    expected: ISOArchitectureDetection
) throws {
    let url = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString
    )
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    try Data(contents.utf8).write(to: url)

    #expect(
        try ISOArchitectureDetector.detect(at: url, chunkSize: 7) == expected
    )
}

@Test
func hashesFilesWithoutLoadingThemWhole() throws {
    let url = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString
    )
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    try Data("simplevm".utf8).write(to: url)

    #expect(
        try FileSHA256.digest(of: url, chunkSize: 3)
            == "e804c4291aa0961391947eb492978db71669ecd3cc7cf726554ea22faddda57d"
    )
}

@Test
func createsSectorAlignedSparseDisk() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let url = directory.appending(path: "disk.raw")
    let capacity = try SparseDiskCreator.create(
        at: url,
        capacityBytes: 1_001
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

    #expect(capacity == 1_024)
    #expect((attributes[.size] as? NSNumber)?.uint64Value == capacity)
}

@Test
func downloadsAndVerifiesImageBeforePromotion() async throws {
    let payload = StubURLProtocol.payload

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = ImageDownloadClient(configuration: configuration)
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destinationURL = directory.appending(path: "artifact.iso")

    let resultURL = try await client.download(
        from: URL(string: "https://example.test/image.iso")!,
        to: destinationURL,
        expectedSHA256: "46ac7da26efed9ba819488520f267336bb3e6703ab8a540d688f54e141d45abc"
    ) { _ in }

    #expect(resultURL == destinationURL)
    #expect(try Data(contentsOf: destinationURL) == payload)
}

@Test
func reportsHTTPFailureSeparatelyFromChecksumFailure() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = ImageDownloadClient(configuration: configuration)
    let destinationURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString
    )
    defer {
        try? FileManager.default.removeItem(at: destinationURL)
    }

    await #expect(throws: ImageDownloadError.httpStatus(404)) {
        try await client.download(
            from: URL(string: "https://example.test/missing.iso")!,
            to: destinationURL,
            expectedSHA256: String(repeating: "0", count: 64)
        ) { _ in }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data("verified image".utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let statusCode = request.url?.lastPathComponent == "missing.iso"
            ? 404
            : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: [
                "Content-Length": String(Self.payload.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
