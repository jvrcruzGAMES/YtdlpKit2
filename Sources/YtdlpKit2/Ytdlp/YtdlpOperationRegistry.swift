import Foundation
import YtdlpKit2Native

private struct NativeEvent: Decodable {
    let type: String
    let path: String?
    let progress: YtdlpDownloadProgress?
    let postProcessing: YtdlpPostProcessingProgress?
}

final class YtdlpOperationRegistry: @unchecked Sendable {
    static let shared = YtdlpOperationRegistry()

    private struct Entry {
        var cancelled = false
        let continuation: AsyncStream<YtdlpDownloadEvent>.Continuation
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {
        YtdlpKit2_SetEventCallback(YtdlpKit2SwiftEmitEvent)
        YtdlpKit2_SetLogCallback(YtdlpKit2SwiftEmitLog)
        YtdlpKit2_SetCancellationCallback(YtdlpKit2SwiftIsCancelled)
        MediaBridgeRegistration.install()
    }

    func register(_ id: UUID) -> AsyncStream<YtdlpDownloadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: YtdlpDownloadEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        lock.withLock { entries[id.uuidString] = Entry(continuation: continuation) }
        continuation.onTermination = { [weak self] _ in self?.cancel(id.uuidString) }
        return stream
    }

    func emit(_ event: YtdlpDownloadEvent, operationID: String) {
        let continuation = lock.withLock { entries[operationID]?.continuation }
        continuation?.yield(event)
    }

    func finish(_ id: UUID) {
        let continuation = lock.withLock { entries.removeValue(forKey: id.uuidString)?.continuation }
        continuation?.finish()
    }

    func cancel(_ operationID: String) {
        lock.withLock { entries[operationID]?.cancelled = true }
        if let id = UUID(uuidString: operationID) {
            Task { await MediaProcessingCenter.shared.cancel(operationID: id) }
        }
    }

    func isCancelled(_ operationID: String) -> Bool {
        lock.withLock { entries[operationID]?.cancelled ?? true }
    }

    func receive(operationID: String, json: String) {
        guard let data = json.data(using: .utf8),
              let native = try? JSONDecoder().decode(NativeEvent.self, from: data) else { return }
        switch native.type {
        case "started": emit(.downloadStarted, operationID: operationID)
        case "progress": if let progress = native.progress { emit(.progress(progress), operationID: operationID) }
        case "postprocessing": if let progress = native.postProcessing {
            emit(.postProcessing(progress), operationID: operationID)
        }
        case "file": if let path = native.path { emit(.fileCompleted(URL(fileURLWithPath: path)), operationID: operationID) }
        default: break
        }
    }
}

@_cdecl("YtdlpKit2SwiftEmitEvent")
private func YtdlpKit2SwiftEmitEvent(
    _ operationID: UnsafePointer<CChar>?, _ payload: UnsafePointer<CChar>?
) {
    guard let operationID, let payload else { return }
    YtdlpOperationRegistry.shared.receive(
        operationID: String(cString: operationID), json: String(cString: payload)
    )
}

@_cdecl("YtdlpKit2SwiftEmitLog")
private func YtdlpKit2SwiftEmitLog(
    _ operationID: UnsafePointer<CChar>?, _ level: UnsafePointer<CChar>?,
    _ message: UnsafePointer<CChar>?
) {
    guard let level, let message else { return }
    let id = operationID.map(String.init(cString:)) ?? ""
    let levelString = String(cString: level)
    let text = String(cString: message)
    if levelString == "warning" || levelString == "error" {
        YtdlpOperationRegistry.shared.emit(.warning(text), operationID: id)
    }
    YtdlpLog.python.debug("yt-dlp [\(levelString, privacy: .public)]: \(text, privacy: .public)")
}

@_cdecl("YtdlpKit2SwiftIsCancelled")
private func YtdlpKit2SwiftIsCancelled(_ operationID: UnsafePointer<CChar>?) -> Int32 {
    guard let operationID else { return 1 }
    return YtdlpOperationRegistry.shared.isCancelled(String(cString: operationID)) ? 1 : 0
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
