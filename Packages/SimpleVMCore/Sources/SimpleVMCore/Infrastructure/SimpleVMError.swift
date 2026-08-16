import Foundation

public enum SimpleVMError: LocalizedError, Sendable {
    case storageInitialization(String)

    public var errorDescription: String? {
        switch self {
        case .storageInitialization(let message):
            "SimpleVM could not initialize its storage: \(message)"
        }
    }
}

