import Foundation

/// Swift-friendly options for metadata extraction and downloads.
public struct YtdlpOptions: Sendable, Codable, Hashable {
    public var cookiesFile: URL?
    public var username: String?
    public var password: String?
    public var videoPassword: String?
    public var userAgent: String?
    public var referer: String?
    public var proxy: String?
    public var geoBypass: Bool?
    public var socketTimeout: Double?
    public var playlistStart: Int?
    public var playlistEnd: Int?
    public var playlistItems: String?
    public var ignoreErrors: Bool
    public var noCheckCertificates: Bool
    public var extractFlat: Bool
    public var allowUnplayableFormats: Bool
    public var httpHeaders: [String: String]
    public var additionalOptions: [String: JSONValue]

    public init(
        cookiesFile: URL? = nil,
        username: String? = nil,
        password: String? = nil,
        videoPassword: String? = nil,
        userAgent: String? = nil,
        referer: String? = nil,
        proxy: String? = nil,
        geoBypass: Bool? = nil,
        socketTimeout: Double? = nil,
        playlistStart: Int? = nil,
        playlistEnd: Int? = nil,
        playlistItems: String? = nil,
        ignoreErrors: Bool = false,
        noCheckCertificates: Bool = false,
        extractFlat: Bool = false,
        allowUnplayableFormats: Bool = false,
        httpHeaders: [String: String] = [:],
        additionalOptions: [String: JSONValue] = [:]
    ) {
        self.cookiesFile = cookiesFile; self.username = username; self.password = password
        self.videoPassword = videoPassword; self.userAgent = userAgent; self.referer = referer
        self.proxy = proxy; self.geoBypass = geoBypass; self.socketTimeout = socketTimeout
        self.playlistStart = playlistStart; self.playlistEnd = playlistEnd
        self.playlistItems = playlistItems; self.ignoreErrors = ignoreErrors
        self.noCheckCertificates = noCheckCertificates; self.extractFlat = extractFlat
        self.allowUnplayableFormats = allowUnplayableFormats; self.httpHeaders = httpHeaders
        self.additionalOptions = additionalOptions
    }
}

/// yt-dlp format selection with an escape hatch for its full expression syntax.
public enum YtdlpFormatSelection: Sendable, Codable, Hashable {
    case best
    case bestVideo
    case bestAudio
    case formatID(String)
    case expression(String)

    var expression: String {
        switch self {
        case .best: "best"
        case .bestVideo: "bestvideo"
        case .bestAudio: "bestaudio"
        case let .formatID(value), let .expression(value): value
        }
    }
}

public enum YtdlpAudioFormat: String, Sendable, Codable, Hashable {
    case best, aac, alac, flac, m4a, mp3, opus, vorbis, wav
}

public struct YtdlpAudioExtraction: Sendable, Codable, Hashable {
    public var format: YtdlpAudioFormat
    /// yt-dlp quality value such as `0` (best VBR) or `192K`.
    public var quality: String?

    public init(format: YtdlpAudioFormat = .best, quality: String? = nil) {
        self.format = format; self.quality = quality
    }
}

public enum YtdlpRemuxFormat: String, Sendable, Codable, Hashable {
    case aac, flac, m4a, mkv, mov, mp3, mp4, ogg, opus, webm
}

/// Describes a single in-process yt-dlp download operation.
public struct YtdlpRequest: Sendable, Codable, Hashable {
    public let url: URL
    public let outputDirectory: URL
    public var outputTemplate: String?
    public var format: YtdlpFormatSelection
    public var options: YtdlpOptions
    public var overwriteExisting: Bool
    public var continuePartialDownloads: Bool
    public var writeThumbnail: Bool
    public var writeMetadataJSON: Bool
    public var writeSubtitles: Bool
    public var writeAutomaticSubtitles: Bool
    public var subtitleLanguages: [String]
    public var audioExtraction: YtdlpAudioExtraction?
    public var remux: YtdlpRemuxFormat?
    public var embedMetadata: Bool
    public var embedThumbnail: Bool
    public var embedSubtitles: Bool

    public init(url: URL, outputDirectory: URL,
                outputTemplate: String? = nil, format: YtdlpFormatSelection = .best,
                options: YtdlpOptions = .init(), overwriteExisting: Bool = false,
                continuePartialDownloads: Bool = true, writeThumbnail: Bool = false,
                writeMetadataJSON: Bool = false, writeSubtitles: Bool = false,
                writeAutomaticSubtitles: Bool = false, subtitleLanguages: [String] = [],
                audioExtraction: YtdlpAudioExtraction? = nil,
                remux: YtdlpRemuxFormat? = nil, embedMetadata: Bool = false,
                embedThumbnail: Bool = false, embedSubtitles: Bool = false) {
        self.url = url; self.outputDirectory = outputDirectory; self.outputTemplate = outputTemplate
        self.format = format; self.options = options; self.overwriteExisting = overwriteExisting
        self.continuePartialDownloads = continuePartialDownloads; self.writeThumbnail = writeThumbnail
        self.writeMetadataJSON = writeMetadataJSON; self.writeSubtitles = writeSubtitles
        self.writeAutomaticSubtitles = writeAutomaticSubtitles; self.subtitleLanguages = subtitleLanguages
        self.audioExtraction = audioExtraction; self.remux = remux
        self.embedMetadata = embedMetadata; self.embedThumbnail = embedThumbnail
        self.embedSubtitles = embedSubtitles
    }
}
