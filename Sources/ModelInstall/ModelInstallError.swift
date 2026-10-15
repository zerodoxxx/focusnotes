import Foundation

/// Errors from the opt-in semantic-model download. Descriptions are shown to the user as written.
public enum ModelInstallError: Error, Sendable, Equatable, LocalizedError {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case network(String)
    case httpStatus(Int, host: String)
    case insecureRedirect(String)
    case checksumMismatch(file: String)
    case extractionFailed(String)
    case missingBundledResource(String)
    case io(String)
    /// A guard refused the request right now (another operation is running, or the state is unknown). The message is shown as-is.
    case unavailable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(required, available):
            let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough free disk space. Semantic search needs about \(needed) free; \(free) is available."
        case let .network(detail):
            return "The download failed: \(detail). Check your connection and try again; it resumes where it stopped."
        case let .httpStatus(code, host):
            return "The server \(host) returned HTTP \(code)."
        case .insecureRedirect:
            return "The download was redirected to an insecure address and was stopped."
        case let .checksumMismatch(file):
            return "\(file) failed its integrity check and was discarded. Try again later."
        case let .extractionFailed(detail):
            return "Couldn't unpack ONNX Runtime: \(detail)."
        case let .missingBundledResource(name):
            return "The app is missing \(name). Reinstall the app."
        case let .io(detail):
            return "Couldn't write the model files: \(detail)."
        case let .unavailable(message):
            return message
        case .cancelled:
            return "The download was cancelled."
        }
    }
}
