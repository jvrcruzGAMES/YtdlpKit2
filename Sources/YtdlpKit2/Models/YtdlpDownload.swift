import Foundation

/// A throttled snapshot from yt-dlp's official progress hook.
public struct YtdlpDownloadProgress: Sendable, Codable, Hashable {
    public let status: String
    public let filename: String?
    public let temporaryFilename: String?
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    public let estimatedTotalBytes: Int64?
    public let speedBytesPerSecond: Double?
    public let eta: Double?
    public let elapsed: Double?
    public let fragmentIndex: Int?
    public let fragmentCount: Int?

    public var fractionCompleted: Double? {
        guard let downloadedBytes,
              let total = totalBytes ?? estimatedTotalBytes,
              total > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(total)))
    }
}

/// Files and metadata produced by a completed download.
public struct YtdlpDownloadResult: Sendable, Codable, Hashable {
    public let mediaInfo: YtdlpMediaInfo
    public let files: [URL]
    public let primaryFile: URL?
    public let outputDirectory: URL
}

public struct YtdlpPostProcessingProgress: Sendable, Codable, Hashable {
    public let operation: String
    public let time: Double?
    public let duration: Double?
    public let speed: Double?
    public let frame: Int64?
    public let fps: Double?
    public let bitrate: Double?
    public let outputSize: Int64?
}

/// Lifecycle and progress values emitted by a download task.
public enum YtdlpDownloadEvent: Sendable, Hashable {
    case preparing
    case extracting(String?)
    case downloadStarted
    case progress(YtdlpDownloadProgress)
    case postProcessing(YtdlpPostProcessingProgress)
    case fileCompleted(URL)
    case warning(String)
    case message(String)
    case finished(YtdlpDownloadResult)
}

/// A cancellable in-process download and its bounded event stream.
public final class YtdlpDownloadTask: @unchecked Sendable {
    public let id: UUID
    public let events: AsyncStream<YtdlpDownloadEvent>
    private let resultTask: Task<YtdlpDownloadResult, Error>
    private let cancelAction: @Sendable () -> Void

    init(id: UUID, events: AsyncStream<YtdlpDownloadEvent>,
         resultTask: Task<YtdlpDownloadResult, Error>,
         cancelAction: @escaping @Sendable () -> Void) {
        self.id = id; self.events = events; self.resultTask = resultTask
        self.cancelAction = cancelAction
    }

    public var value: YtdlpDownloadResult {
        get async throws { try await resultTask.value }
    }

    public func cancel() async {
        cancelAction()
        resultTask.cancel()
    }
}
