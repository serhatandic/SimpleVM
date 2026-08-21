import Foundation

public enum WindowsSupportToolsDescriptor {
    public static let version = "0.1.272"
    public static let release = "v10.0.12-utm"
    public static let sourceFileName = "utm-guest-tools-0.1.272.iso"
    public static let safeFileName = "simplevm-windows-support-0.1.272.iso"
    public static let sourceSizeBytes: Int64 = 139_229_184
    public static let sourceSHA256 =
        "6090ac5b7c01c320ba860fea2c5697a86c9406504acf8183db3eea533bb5224a"
    public static let sourceURL = URL(
        string:
            "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/utm-guest-tools-0.1.272.iso"
    )!
}

public enum WindowsSupportToolsPhase: Equatable, Sendable {
    case downloading(fractionCompleted: Double)
    case verifying
    case buildingSafeMedia
}

public actor WindowsSupportToolsManager {
    private let layout: StorageLayout
    private let downloader: ImageDownloadClient

    public init(
        layout: StorageLayout,
        downloader: ImageDownloadClient = ImageDownloadClient()
    ) {
        self.layout = layout
        self.downloader = downloader
    }

    public func cachedURL() -> URL? {
        let url = supportDirectoryURL.appending(
            path: WindowsSupportToolsDescriptor.safeFileName
        )
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func prepare(
        progress: @escaping @Sendable (WindowsSupportToolsPhase) -> Void = { _ in }
    ) async throws -> URL {
        let fileManager = FileManager.default
        try layout.initialize(fileManager: fileManager)
        try fileManager.createDirectory(
            at: supportDirectoryURL,
            withIntermediateDirectories: true
        )

        let sourceURL = supportDirectoryURL.appending(
            path: WindowsSupportToolsDescriptor.sourceFileName
        )
        let safeURL = supportDirectoryURL.appending(
            path: WindowsSupportToolsDescriptor.safeFileName
        )

        if fileManager.fileExists(atPath: sourceURL.path) {
            progress(.verifying)
            if try !Self.isExpectedSource(sourceURL, fileManager: fileManager) {
                try fileManager.removeItem(at: sourceURL)
                if fileManager.fileExists(atPath: safeURL.path) {
                    try fileManager.removeItem(at: safeURL)
                }
            }
        }

        if !fileManager.fileExists(atPath: sourceURL.path) {
            _ = try await downloader.download(
                from: WindowsSupportToolsDescriptor.sourceURL,
                to: sourceURL,
                expectedSHA256: WindowsSupportToolsDescriptor.sourceSHA256
            ) { phase in
                switch phase {
                case .downloading(let fractionCompleted):
                    progress(.downloading(
                        fractionCompleted: fractionCompleted
                    ))
                case .verifying:
                    progress(.verifying)
                }
            }
        }

        if fileManager.fileExists(atPath: safeURL.path) {
            return safeURL
        }

        progress(.buildingSafeMedia)
        return try await Task.detached(priority: .userInitiated) {
            try WindowsSupportMediaBuilder.build(
                from: sourceURL,
                to: safeURL
            )
            return safeURL
        }.value
    }

    public func removeCachedMedia() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: supportDirectoryURL.path) {
            try fileManager.removeItem(at: supportDirectoryURL)
        }
    }

    private var supportDirectoryURL: URL {
        layout.downloadsURL.appending(
            path: "WindowsSupport",
            directoryHint: .isDirectory
        )
    }

    private static func isExpectedSource(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value
        guard size == WindowsSupportToolsDescriptor.sourceSizeBytes else {
            return false
        }
        return try FileSHA256.digest(of: url)
            == WindowsSupportToolsDescriptor.sourceSHA256
    }
}

public enum WindowsSupportMediaManifest {
    public static let volumeName = "SimpleVM Drivers"
    public static let expectedDriveLetter = "E"
    public static let driverNames = [
        "Balloon",
        "NetKVM",
        "pvpanic",
        "viogpudo",
        "vioinput",
        "viomem",
        "viorng",
        "vioscsi",
        "vioserial",
        "viostor"
    ]
    public static let automaticallyStagedDriverNames = [
        "NetKVM",
        "viorng",
        "vioserial"
    ]
}

public enum WindowsDriverAnswerFile {
    public static let data = Data(contents.utf8)

    public static func validate() throws {
        let lowercased = contents.lowercased()
        let forbidden = [
            "productkey",
            "enablelua",
            "labconfig",
            "bypasstpmcheck",
            "bypasssecurebootcheck",
            "bypasscpucheck",
            "bypassramcheck",
            "skiprearm",
            "skipautoactivation",
            "oobesystem",
            "firstlogoncommands",
            "skipwinreinitialization",
            "hideonlineaccountscreens",
            "protectyourpc",
            "<credentials>"
        ]
        guard forbidden.allSatisfy({ !lowercased.contains($0) }),
              lowercased.contains(#"pass="windowspe""#),
              lowercased.contains(#"pass="offlineservicing""#),
              lowercased.contains("pnpcustomizationswinpe"),
              lowercased.contains("pnpcustomizationsnonwinpe") else {
            throw WindowsSupportToolsError.invalidAnswerFile
        }
    }

    private static let contents = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>E:\Drivers\NetKVM\w11\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>E:\Drivers\viorng\w11\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3">
              <Path>E:\Drivers\vioserial\w11\ARM64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>
      <settings pass="offlineServicing">
        <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>E:\Drivers\NetKVM\w11\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>E:\Drivers\viorng\w11\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3">
              <Path>E:\Drivers\vioserial\w11\ARM64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>
    </unattend>
    """#
}

public enum WindowsSupportMediaBuilder {
    public static func build(
        from sourceISOURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try WindowsDriverAnswerFile.validate()
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let workURL = parentURL.appending(
            path: ".windows-support-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let mountURL = workURL.appending(
            path: "Mounted",
            directoryHint: .isDirectory
        )
        let stagingURL = workURL.appending(
            path: "Staging",
            directoryHint: .isDirectory
        )
        let partialURL = workURL.appending(path: "support.iso")
        try fileManager.createDirectory(
            at: mountURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        defer {
            try? runHdiutil(["detach", mountURL.path])
            try? fileManager.removeItem(at: workURL)
        }

        try runHdiutil([
            "attach",
            "-readonly",
            "-nobrowse",
            "-mountpoint",
            mountURL.path,
            sourceISOURL.path
        ])
        try stage(
            fromMountedURL: mountURL,
            to: stagingURL,
            fileManager: fileManager
        )
        try runHdiutil([
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name",
            WindowsSupportMediaManifest.volumeName,
            "-o",
            partialURL.path,
            stagingURL.path
        ])

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: partialURL
            )
        } else {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        }
    }

    public static func stage(
        fromMountedURL sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try WindowsDriverAnswerFile.validate()
        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        let destinationDriversURL = destinationURL.appending(
            path: "Drivers",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: destinationDriversURL,
            withIntermediateDirectories: true
        )

        for driverName in WindowsSupportMediaManifest.driverNames {
            let sourceDriverURL = sourceURL.appending(
                path: "Drivers/\(driverName)/w11/ARM64",
                directoryHint: .isDirectory
            )
            guard fileManager.fileExists(atPath: sourceDriverURL.path),
                  try containsDriverPackage(
                    at: sourceDriverURL,
                    fileManager: fileManager
                  ) else {
                throw WindowsSupportToolsError.missingDriver(driverName)
            }
            let destinationDriverURL = destinationDriversURL
                .appending(path: driverName, directoryHint: .isDirectory)
                .appending(path: "w11", directoryHint: .isDirectory)
                .appending(path: "ARM64", directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: destinationDriverURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(
                at: sourceDriverURL,
                to: destinationDriverURL
            )
        }

        for fileName in ["utm-guest-tools.exe", "virtio-win_license.txt"] {
            let sourceFileURL = sourceURL.appending(path: fileName)
            guard fileManager.fileExists(atPath: sourceFileURL.path) else {
                throw WindowsSupportToolsError.missingPayload(fileName)
            }
            try fileManager.copyItem(
                at: sourceFileURL,
                to: destinationURL.appending(path: fileName)
            )
        }

        try WindowsDriverAnswerFile.data.write(
            to: destinationURL.appending(path: "Autounattend.xml"),
            options: .atomic
        )
        let readme = """
        SimpleVM Windows Support Media

        Windows Setup uses this media only to stage signed ARM64 VirtIO drivers.
        It does not supply a product key, bypass Windows requirements, create an
        account, change privacy settings, disable UAC, or alter Windows Recovery.

        After Windows setup finishes, run utm-guest-tools.exe yourself to install
        optional third-party SPICE integration. The installer is provided by UTM.
        """
        try Data(readme.utf8).write(
            to: destinationURL.appending(path: "README.txt"),
            options: .atomic
        )
    }

    private static func containsDriverPackage(
        at url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let extensions = Set(
            try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ).map { $0.pathExtension.lowercased() }
        )
        return extensions.isSuperset(of: ["cat", "inf", "sys"])
    }

    private static func runHdiutil(_ arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WindowsSupportToolsError.commandFailed(
                message.isEmpty ? "hdiutil exited with an error." : message
            )
        }
    }
}

public enum WindowsSupportToolsError: LocalizedError, Equatable {
    case invalidAnswerFile
    case missingDriver(String)
    case missingPayload(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAnswerFile:
            "The generated Windows driver answer file is unsafe."
        case .missingDriver(let name):
            "The pinned Windows support image is missing the \(name) ARM64 driver."
        case .missingPayload(let name):
            "The pinned Windows support image is missing \(name)."
        case .commandFailed(let message):
            "Could not build safe Windows support media: \(message)"
        }
    }
}
