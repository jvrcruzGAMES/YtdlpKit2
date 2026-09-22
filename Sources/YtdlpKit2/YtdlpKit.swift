    import Foundation

public actor YtdlpKit {
    public static let shared = YtdlpKit()
    public nonisolated let packages: YtdlpPackageManager
    public nonisolated let plugins: YtdlpPluginManager
    public nonisolated let mediaProcessing = YtdlpMediaProcessing()

    private let configuration: YtdlpConfiguration

    public init(configuration: YtdlpConfiguration = .init()) {
        self.configuration = configuration
        let packageManager = YtdlpPackageManager(configuration: configuration)
        packages = packageManager
        plugins = YtdlpPluginManager(configuration: configuration, packages: packageManager)
    }

    public func prepare() async throws {
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        try await runtime.prepare()
        try await packages.prepare()
        try await plugins.validateRequiredPlugins()
    }

    public func runtimeStatus() async -> RuntimeStatus {
        if let runtime = await RuntimeStore.shared.current() {
            let base = await runtime.status()
            let inventory = (try? await plugins.installedPlugins()) ?? []
            let capabilities = inventory.flatMap(\.capabilities)
            let providers = capabilities.compactMap { capability -> YtdlpJSChallengeProvider? in
                if case let .javaScriptChallengeProvider(value) = capability { value } else { nil }
            }
            var status = RuntimeStatus(
                state: base.state, pythonVersion: base.pythonVersion,
                pythonImplementation: base.pythonImplementation, platform: base.platform,
                architecture: base.architecture, sitePackagesDirectory: base.sitePackagesDirectory,
                searchPaths: base.searchPaths, nativeBridgeVersion: base.nativeBridgeVersion,
                ytdlpInstalled: base.ytdlpInstalled, ytdlpVersion: base.ytdlpVersion,
                pluginCount: inventory.count,
                pluginExtractorCount: capabilities.reduce(0) {
                    if case .extractor = $1 { $0 + 1 } else { $0 }
                },
                pluginPostProcessorCount: capabilities.reduce(0) {
                    if case .postProcessor = $1 { $0 + 1 } else { $0 }
                },
                jsChallengeProviders: providers,
                requiredPluginsHealthy: providers.contains {
                    $0.name == "apple-webkit-jsi" && $0.available
                }
            )
            if let media = try? await mediaProcessing.capabilities() {
                status.ffmpegAvailable = media.ffmpegAvailable
                status.ffprobeAvailable = media.ffprobeAvailable
                status.ffmpegVersion = media.version
                status.ffmpegKitNextVersion = media.backendVersion
                status.ffmpegBuildConfiguration = media.buildConfiguration
                status.hardwareAcceleration = media.hardwareAcceleration
            }
            return status
        }
        let environment = try? PythonEnvironment(baseDirectory: configuration.applicationSupportDirectory)
        var status = RuntimeStatus(
            state: .uninitialized,
            pythonVersion: nil,
            pythonImplementation: nil,
            platform: nil,
            architecture: nil,
            sitePackagesDirectory: environment?.sitePackagesDirectory
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "YtdlpKit2/python/site-packages"),
            searchPaths: [],
            nativeBridgeVersion: nil,
            ytdlpInstalled: false,
            ytdlpVersion: nil,
            pluginCount: 0, pluginExtractorCount: 0, pluginPostProcessorCount: 0,
            jsChallengeProviders: [], requiredPluginsHealthy: false
        )
        if let media = try? await mediaProcessing.capabilities() {
            status.ffmpegAvailable = media.ffmpegAvailable
            status.ffprobeAvailable = media.ffprobeAvailable
            status.ffmpegVersion = media.version
            status.ffmpegKitNextVersion = media.backendVersion
            status.ffmpegBuildConfiguration = media.buildConfiguration
            status.hardwareAcceleration = media.hardwareAcceleration
        }
        return status
    }

    /// Returns the version reported by the imported yt-dlp module.
    public func ytdlpVersion() async throws -> YtdlpVersion {
        try await prepare()
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        return try await runtime.ytdlpVersion()
    }

    /// Extracts metadata without downloading media.
    public func extractInfo(
        from url: URL, options: YtdlpOptions = .init()
    ) async throws -> YtdlpMediaInfo {
        try await prepare()
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        let json = try YtdlpBridge.optionsJSON(options)
        return try await runtime.extractInfo(url: url, optionsJSON: json)
    }

    /// Starts a bounded-event, cancellable download using yt-dlp's Python API.
    public func startDownload(_ request: YtdlpRequest) async throws -> YtdlpDownloadTask {
        try await prepare()
        let mediaAvailable = (try? await MediaProcessingCenter.shared.capabilities().ffmpegAvailable) ?? false
        if request.format.expression.contains("+") && !mediaAvailable {
            throw YtdlpError.downloadFailed(
                "This format requires FFmpeg merging, which is not available in the current YtdlpKit2 runtime."
            )
        }
        let access = SecurityScopedAccess(request.outputDirectory)
        do {
            try FileManager.default.createDirectory(
                at: request.outputDirectory, withIntermediateDirectories: true
            )
        } catch {
            throw YtdlpKitError.filesystemError(error.localizedDescription)
        }
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        let optionsJSON = try YtdlpBridge.downloadOptionsJSON(request)
        let id = UUID()
        let registry = YtdlpOperationRegistry.shared
        let stream = registry.register(id)
        registry.emit(.preparing, operationID: id.uuidString)
        registry.emit(.extracting(request.url.host), operationID: id.uuidString)

        let resultTask = Task<YtdlpDownloadResult, Error> {
            _ = access
            do {
                if Task.isCancelled { throw CancellationError() }
                let result = try await runtime.download(
                    request: request, optionsJSON: optionsJSON, operationID: id
                )
                registry.emit(.finished(result), operationID: id.uuidString)
                registry.finish(id)
                return result
            } catch YtdlpError.cancelled {
                registry.finish(id)
                throw CancellationError()
            } catch {
                registry.finish(id)
                throw error
            }
        }
        return YtdlpDownloadTask(
            id: id, events: stream, resultTask: resultTask,
            cancelAction: { registry.cancel(id.uuidString) }
        )
    }

    /// Downloads and waits for completion. Use `startDownload` to observe events.
    public func download(_ request: YtdlpRequest) async throws -> YtdlpDownloadResult {
        let operation = try await startDownload(request)
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            Task { await operation.cancel() }
        }
    }

    func testYtdlpCallbacks(operationID: UUID) async throws -> String {
        try await prepare()
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        return try await runtime.testYtdlpCallbacks(operationID: operationID)
    }

    func testFFmpegBridge() async throws -> String {
        try await prepare()
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        return try await runtime.testFFmpegBridge()
    }

    func testFFmpegMerge(video: URL, audio: URL, output: URL) async throws -> String {
        try await prepare()
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        return try await runtime.testFFmpegMerge(
            video: video, audio: audio, output: output, operationID: UUID())
    }

    /// Removes user-installed packages and rebuilds managed core packages.
    public func resetPythonEnvironment() async throws {
        try await packages.resetPythonEnvironment()
    }

}

/// CPython is process-global. This store guarantees that even independently
/// constructed `YtdlpKit` values converge on the same runtime actor.
actor RuntimeStore {
    static let shared = RuntimeStore()
    private var runtime: PythonRuntime?

    func acquire(configuration: YtdlpConfiguration) throws -> PythonRuntime {
        if let runtime { return runtime }
        let created = try PythonRuntime(configuration: configuration)
        runtime = created
        return created
    }

    func current() -> PythonRuntime? { runtime }
}
