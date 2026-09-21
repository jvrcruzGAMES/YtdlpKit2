import Foundation

/// Structured failures translated from yt-dlp and its Python bridge.
public enum YtdlpError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedURL(String)
    case extractionFailed(String)
    case downloadFailed(String)
    case loginRequired(String)
    case authenticationFailed(String)
    case geoRestricted(String)
    case unavailable(String)
    case network(String)
    case cancelled
    case python(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedURL(v): "Unsupported URL: \(v)"
        case let .extractionFailed(v): "Extraction failed: \(v)"
        case let .downloadFailed(v): "Download failed: \(v)"
        case let .loginRequired(v): "Login required: \(v)"
        case let .authenticationFailed(v): "Authentication failed: \(v)"
        case let .geoRestricted(v): "Geo-restricted: \(v)"
        case let .unavailable(v): "Media unavailable: \(v)"
        case let .network(v): "Network error: \(v)"
        case .cancelled: "The yt-dlp operation was cancelled."
        case let .python(v): "Python error: \(v)"
        case let .unknown(v): v
        }
    }
}
