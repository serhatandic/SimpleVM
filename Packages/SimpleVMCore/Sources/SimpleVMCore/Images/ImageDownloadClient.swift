import Foundation

public enum ImageDownloadPhase: Equatable, Sendable {
    case downloading(fractionCompleted: Double)
    case verifying
}

public enum ImageDownloadError: LocalizedError, Equatable {
    case invalidResponse
    case checksumMismatch(expected: String, actual: String)
    case incompleteDownload

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The image server returned an invalid response."
        case .checksumMismatch:
            "The downloaded image failed checksum verification."
        case .incompleteDownload:
            "The image download did not produce a file."
        }
    }
}

public final class ImageDownloadClient:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    public typealias ProgressHandler = @Sendable (ImageDownloadPhase) -> Void

    private struct Context {
        let destinationURL: URL
        let expectedSHA256: String
        let progress: ProgressHandler
        let continuation: CheckedContinuation<URL, any Error>
        var receivedFile = false
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?

        func set(_ task: URLSessionDownloadTask) {
            lock.withLock {
                self.task = task
            }
        }

        func cancel() {
            lock.withLock {
                task?.cancel()
            }
        }
    }

    private let fileManager: FileManager
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    public init(
        configuration: URLSessionConfiguration = .default,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        super.init()
    }

    public func download(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedSHA256: String,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: remoteURL)
                let context = Context(
                    destinationURL: destinationURL,
                    expectedSHA256: expectedSHA256.lowercased(),
                    progress: progress,
                    continuation: continuation
                )
                lock.withLock {
                    contexts[task.taskIdentifier] = context
                }
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let progress = lock.withLock({
                  contexts[downloadTask.taskIdentifier]?.progress
              }) else {
            return
        }

        progress(
            .downloading(
                fractionCompleted: min(
                    1,
                    Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                )
            )
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard var context = lock.withLock({
            contexts[downloadTask.taskIdentifier]
        }) else {
            return
        }

        do {
            let parentURL = context.destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )

            let partialURL = context.destinationURL.appendingPathExtension("partial")
            if fileManager.fileExists(atPath: partialURL.path) {
                try fileManager.removeItem(at: partialURL)
            }
            try fileManager.moveItem(at: location, to: partialURL)
            context.receivedFile = true
            lock.withLock {
                contexts[downloadTask.taskIdentifier] = context
            }
            context.progress(.verifying)

            let actualSHA256 = try FileSHA256.digest(of: partialURL)
            guard actualSHA256 == context.expectedSHA256 else {
                try? fileManager.removeItem(at: partialURL)
                finish(
                    taskIdentifier: downloadTask.taskIdentifier,
                    result: .failure(
                        ImageDownloadError.checksumMismatch(
                            expected: context.expectedSHA256,
                            actual: actualSHA256
                        )
                    )
                )
                return
            }

            if fileManager.fileExists(atPath: context.destinationURL.path) {
                try fileManager.removeItem(at: context.destinationURL)
            }
            try fileManager.moveItem(at: partialURL, to: context.destinationURL)
            finish(
                taskIdentifier: downloadTask.taskIdentifier,
                result: .success(context.destinationURL)
            )
        } catch {
            finish(
                taskIdentifier: downloadTask.taskIdentifier,
                result: .failure(error)
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
            return
        }

        let receivedFile = lock.withLock {
            contexts[task.taskIdentifier]?.receivedFile
        }
        if receivedFile == false {
            finish(
                taskIdentifier: task.taskIdentifier,
                result: .failure(ImageDownloadError.incompleteDownload)
            )
        }
    }

    private func finish(
        taskIdentifier: Int,
        result: Result<URL, any Error>
    ) {
        let context = lock.withLock {
            contexts.removeValue(forKey: taskIdentifier)
        }
        context?.continuation.resume(with: result)
    }
}
