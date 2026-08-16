import Foundation

public enum AppleLinuxBootAssets {
    public static let kernelFileName = "linux-kernel"
    public static let initialRamdiskFileName = "linux-initrd"
    public static let commandLineFileName = "linux-command-line"

    public static func install(
        kernelURL: URL,
        initialRamdiskURL: URL?,
        commandLine: String,
        backendStateURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: backendStateURL,
            withIntermediateDirectories: true
        )
        try replace(
            source: kernelURL,
            destination: backendStateURL.appending(path: kernelFileName),
            fileManager: fileManager
        )
        if let initialRamdiskURL {
            try replace(
                source: initialRamdiskURL,
                destination: backendStateURL.appending(
                    path: initialRamdiskFileName
                ),
                fileManager: fileManager
            )
        }
        try Data(commandLine.utf8).write(
            to: backendStateURL.appending(path: commandLineFileName),
            options: .atomic
        )
    }

    public static func load(
        backendStateURL: URL,
        fileManager: FileManager = .default
    ) throws -> (kernelURL: URL, initialRamdiskURL: URL?, commandLine: String)? {
        let kernelURL = backendStateURL.appending(path: kernelFileName)
        guard fileManager.fileExists(atPath: kernelURL.path) else {
            return nil
        }
        let initrdURL = backendStateURL.appending(path: initialRamdiskFileName)
        let commandLineURL = backendStateURL.appending(path: commandLineFileName)
        let commandLine = try String(
            contentsOf: commandLineURL,
            encoding: .utf8
        )
        return (
            kernelURL,
            fileManager.fileExists(atPath: initrdURL.path) ? initrdURL : nil,
            commandLine
        )
    }

    private static func replace(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}

