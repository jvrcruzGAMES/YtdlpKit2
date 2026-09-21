import Foundation

public enum YtdlpKitError: Error, LocalizedError, Sendable {
    case runtimeNotFound
    case incompatibleRuntime(String)
    case pythonInitializationFailed(String)
    case pythonImportFailed(String)
    case pythonExecutionFailed(String)
    case invalidEnvironment(String)
    case filesystemError(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotFound: "The bundled CPython runtime could not be found."
        case let .incompatibleRuntime(message): "Incompatible Python runtime: \(message)"
        case let .pythonInitializationFailed(message): "Python initialization failed: \(message)"
        case let .pythonImportFailed(message): "Python import failed: \(message)"
        case let .pythonExecutionFailed(message): "Python execution failed: \(message)"
        case let .invalidEnvironment(message): "Invalid runtime environment: \(message)"
        case let .filesystemError(message): "Filesystem error: \(message)"
        }
    }
}

public enum MediaProcessingError: Error, LocalizedError, Sendable {
    case ffmpegUnavailable
    case ffmpegFailed(command: [String], exitCode: Int, stderr: String)
    case ffprobeFailed(command: [String], exitCode: Int, stderr: String)
    case unsupportedMediaOperation(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable: "The signed FFmpegKitNext backend is not bundled."
        case let .ffmpegFailed(_, code, stderr): "FFmpeg failed (\(code)): \(stderr)"
        case let .ffprobeFailed(_, code, stderr): "FFprobe failed (\(code)): \(stderr)"
        case let .unsupportedMediaOperation(message): message
        }
    }
}
