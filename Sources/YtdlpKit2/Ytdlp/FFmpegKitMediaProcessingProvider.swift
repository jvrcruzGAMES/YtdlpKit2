import Foundation
import YtdlpKit2Native
#if canImport(ffmpegkit)
import ffmpegkit
#endif

actor MediaProcessingCenter {
    static let shared = MediaProcessingCenter()
    private let provider: any MediaProcessingProvider

    init() {
        #if canImport(ffmpegkit)
        provider = FFmpegKitMediaProcessingProvider()
        #else
        provider = UnavailableMediaProcessingProvider()
        #endif
    }

    func capabilities() async throws -> MediaProcessingCapabilities {
        try await provider.capabilities()
    }

    func execute(kind: String, invocation: FFmpegInvocation) async throws -> FFmpegExecutionResult {
        if kind == "ffprobe" { return try await provider.executeFFprobe(invocation) }
        return try await provider.executeFFmpeg(invocation)
    }

    func cancel(operationID: UUID) async { await provider.cancel(operationID: operationID) }
}

/// The default in-process backend. Its upstream Objective-C types remain private.
public actor FFmpegKitMediaProcessingProvider: MediaProcessingProvider {
    #if canImport(ffmpegkit)
    private var sessions: [UUID: Session] = [:]
    #endif

    public init() {}

    public var isAvailable: Bool {
        get async {
            #if canImport(ffmpegkit)
            true
            #else
            false
            #endif
        }
    }

    public func capabilities() async throws -> MediaProcessingCapabilities {
        #if canImport(ffmpegkit)
        let ffmpeg = try await executeFFmpeg(.init(operationID: UUID(), arguments: ["-version"]))
        let probe = try await executeFFprobe(.init(operationID: UUID(), arguments: ["-version"]))
        let text = ffmpeg.standardOutput + ffmpeg.standardError
        let first = text.split(separator: "\n").first.map(String.init)
        return .init(
            ffmpegAvailable: ffmpeg.returnCode == 0,
            ffprobeAvailable: probe.returnCode == 0,
            version: first,
            backendVersion: FFmpegKitConfig.getVersion(),
            hardwareAcceleration: text.contains("videotoolbox") ? ["videotoolbox"] : [],
            videoToolboxAvailable: text.contains("videotoolbox"),
            buildConfiguration: text.split(separator: "\n").first(where: { $0.contains("configuration:") }).map(String.init)
        )
        #else
        return .init(ffmpegAvailable: false, ffprobeAvailable: false)
        #endif
    }

    public func executeFFmpeg(_ invocation: FFmpegInvocation) async throws -> FFmpegExecutionResult {
        #if canImport(ffmpegkit)
        return try await execute(invocation, probe: false)
        #else
        throw MediaProcessingError.ffmpegUnavailable
        #endif
    }

    public func executeFFprobe(_ invocation: FFprobeInvocation) async throws -> FFprobeExecutionResult {
        #if canImport(ffmpegkit)
        return try await execute(invocation, probe: true)
        #else
        throw MediaProcessingError.ffmpegUnavailable
        #endif
    }

    public func cancel(operationID: UUID) async {
        #if canImport(ffmpegkit)
        sessions[operationID]?.cancel()
        #endif
    }

    #if canImport(ffmpegkit)
    private func execute(_ invocation: FFmpegInvocation, probe: Bool) async throws -> FFmpegExecutionResult {
        // FFmpegKitNext consumes argv directly: no shell parsing or quoting occurs here.
        let oldDirectory = FileManager.default.currentDirectoryPath
        if let directory = invocation.workingDirectory {
            guard FileManager.default.changeCurrentDirectoryPath(directory.path) else {
                throw MediaProcessingError.unsupportedMediaOperation("Unreadable working directory: \(directory.path)")
            }
        }
        defer { FileManager.default.changeCurrentDirectoryPath(oldDirectory) }
        return await withCheckedContinuation { continuation in
            let complete: (Session) -> Void = { session in
                let output = session.getOutput() ?? ""
                let code = Int32(session.getReturnCode()?.getValue() ?? -1)
                let cancelled = session.getReturnCode().map(ReturnCode.isCancel) ?? false
                let result = FFmpegExecutionResult(
                    returnCode: code, standardOutput: probe ? output : "",
                    standardError: probe ? "" : output, cancelled: cancelled)
                Task { self.finish(
                    operationID: invocation.operationID, result: result,
                    continuation: continuation
                ) }
            }
            let session: Session
            if probe {
                session = FFprobeKit.execute(
                    withArgumentsAsync: invocation.arguments,
                    withCompleteCallback: { complete($0!) },
                    withLogCallback: nil)!
            } else {
                session = FFmpegKit.execute(
                    withArgumentsAsync: invocation.arguments,
                    withCompleteCallback: { complete($0!) },
                    withLogCallback: nil,
                    withStatisticsCallback: { statistics in
                        guard let statistics else { return }
                        let progress = YtdlpPostProcessingProgress(
                            operation: "ffmpeg", time: statistics.getTime() / 1_000,
                            duration: nil, speed: statistics.getSpeed(),
                            frame: Int64(statistics.getVideoFrameNumber()),
                            fps: Double(statistics.getVideoFps()),
                            bitrate: statistics.getBitrate(),
                            outputSize: Int64(statistics.getSize()))
                        YtdlpOperationRegistry.shared.emit(
                            .postProcessing(progress),
                            operationID: invocation.operationID.uuidString)
                    })!
            }
            sessions[invocation.operationID] = session
        }
    }

    private func finish(
        operationID: UUID, result: FFmpegExecutionResult,
        continuation: CheckedContinuation<FFmpegExecutionResult, Never>
    ) {
        sessions.removeValue(forKey: operationID)
        continuation.resume(returning: result)
    }
    #endif
}

private final class MediaResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func store(_ newValue: String) { lock.lock(); value = newValue; lock.unlock() }
    func load() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

private func mediaResultJSON(kind: String, operationID: String, argumentsJSON: String) async -> String {
    do {
        let arguments = try JSONDecoder().decode([String].self, from: Data(argumentsJSON.utf8))
        let invocation = FFmpegInvocation(
            operationID: UUID(uuidString: operationID) ?? UUID(), arguments: arguments)
        let result = try await MediaProcessingCenter.shared.execute(kind: kind, invocation: invocation)
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    } catch {
        let escaped = String(describing: error)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"returncode\":127,\"stdout\":\"\",\"stderr\":\"\(escaped)\",\"cancelled\":false}"
    }
}

@_cdecl("YtdlpKit2SwiftExecuteMedia")
private func YtdlpKit2SwiftExecuteMedia(
    _ operationID: UnsafePointer<CChar>?, _ kind: UnsafePointer<CChar>?,
    _ argumentsJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let operationIDPointer = operationID, let kindPointer = kind,
          let argumentsPointer = argumentsJSON else { return strdup("") }
    let operationID = String(cString: operationIDPointer)
    let kind = String(cString: kindPointer)
    let argumentsJSON = String(cString: argumentsPointer)
    let semaphore = DispatchSemaphore(value: 0)
    let response = MediaResponseBox()
    Task.detached {
        response.store(await mediaResultJSON(
            kind: kind, operationID: operationID, argumentsJSON: argumentsJSON))
        semaphore.signal()
    }
    semaphore.wait()
    return strdup(response.load())
}

enum MediaBridgeRegistration {
    static func install() {
        YtdlpKit2_SetMediaCallback(YtdlpKit2SwiftExecuteMedia)
    }
}
