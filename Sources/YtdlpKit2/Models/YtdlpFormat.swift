import Foundation

/// A media format advertised by yt-dlp.
public struct YtdlpFormat: Sendable, Codable, Hashable {
    public let formatID: String
    public let formatNote: String?
    public let `extension`: String?
    public let `protocol`: String?
    public let url: URL?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let videoBitrate: Double?
    public let audioBitrate: Double?
    public let totalBitrate: Double?
    public let filesize: Int64?
    public let filesizeApprox: Int64?
    public let audioSampleRate: Double?
    public let audioChannels: Int?
    public let dynamicRange: String?
    public let language: String?
    public let quality: Double?
    public let preference: Double?
    public let sourcePreference: Double?
    public let container: String?

    public var hasVideo: Bool { videoCodec.map { !$0.isEmpty && $0 != "none" } ?? false }
    public var hasAudio: Bool { audioCodec.map { !$0.isEmpty && $0 != "none" } ?? false }
    public var isAudioOnly: Bool { hasAudio && !hasVideo }
    public var isVideoOnly: Bool { hasVideo && !hasAudio }
}

/// A thumbnail associated with extracted media.
public struct YtdlpThumbnail: Sendable, Codable, Hashable {
    public let url: URL
    public let id: String?
    public let width: Int?
    public let height: Int?
    public let preference: Double?
    public let resolution: String?
}

/// A concrete subtitle representation, such as VTT or SRT.
public struct YtdlpSubtitleFormat: Sendable, Codable, Hashable {
    public let url: URL?
    public let `extension`: String?
    public let name: String?
}

/// Subtitle formats grouped under their original language key.
public struct YtdlpSubtitleTrack: Sendable, Codable, Hashable {
    public let language: String
    public let formats: [YtdlpSubtitleFormat]
}

/// A chapter boundary reported by an extractor.
public struct YtdlpChapter: Sendable, Codable, Hashable {
    public let title: String?
    public let startTime: Double
    public let endTime: Double?
}
