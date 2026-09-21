import Foundation

/// Strongly typed common metadata plus the complete normalized yt-dlp result.
public struct YtdlpMediaInfo: Sendable, Codable, Hashable {
    public let id: String?
    public let title: String?
    public let description: String?
    public let webpageURL: URL?
    public let originalURL: URL?
    public let extractor: String?
    public let extractorKey: String?
    public let uploader: String?
    public let uploaderID: String?
    public let channel: String?
    public let channelID: String?
    public let duration: Double?
    public let timestamp: Double?
    public let uploadDate: String?
    public let viewCount: Int64?
    public let likeCount: Int64?
    public let commentCount: Int64?
    public let ageLimit: Double?
    public let liveStatus: String?
    public let isLive: Bool?
    public let wasLive: Bool?
    public let thumbnailURL: URL?
    public let thumbnails: [YtdlpThumbnail]
    public let formats: [YtdlpFormat]
    public let subtitles: [YtdlpSubtitleTrack]
    public let automaticCaptions: [YtdlpSubtitleTrack]
    public let chapters: [YtdlpChapter]
    public let playlistID: String?
    public let playlistTitle: String?
    public let playlistIndex: Int?
    public let entries: [YtdlpMediaInfo]?
    public let rawJSON: JSONValue
}
