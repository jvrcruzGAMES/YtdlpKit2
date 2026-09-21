import Foundation

/// The version reported by the imported `yt_dlp` module.
public struct YtdlpVersion: Sendable, Codable, Hashable {
    public let string: String
    public init(string: String) { self.string = string }
}
