import Foundation
import YtdlpKit2Native

public actor PythonRuntime {
    public private(set) var state: PythonRuntimeState = .uninitialized

    private let configuration: YtdlpConfiguration
    private let environment: PythonEnvironment
    private var information: RuntimeInformation?
    private var nativeBridgeVersion: String?
    private var configuredPaths: [String] = []
    private var loadedYtdlpVersion: String?
    private var preparationWaiters: [CheckedContinuation<Void, Error>] = []

    public init(configuration: YtdlpConfiguration = .init()) throws {
        self.configuration = configuration
        environment = try PythonEnvironment(baseDirectory: configuration.applicationSupportDirectory)
    }

    public func prepare() async throws {
        switch state {
        case .ready: return
        case .starting:
            return try await withCheckedThrowingContinuation {
                preparationWaiters.append($0)
            }
        case .shuttingDown:
            throw YtdlpKitError.pythonInitializationFailed("runtime is shutting down")
        case .uninitialized:
            break
        case let .failed(message):
            throw YtdlpKitError.pythonInitializationFailed(message)
        }

        state = .starting
        do {
            try environment.createDirectories()
            let result = try RuntimeBootstrap(
                environment: environment,
                configuration: configuration
            ).start()
            information = result.0
            nativeBridgeVersion = result.1
            configuredPaths = result.2
            state = .ready
            let waiters = preparationWaiters
            preparationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        } catch {
            let publicError = error as? YtdlpKitError
                ?? .pythonInitializationFailed(String(describing: error))
            state = .failed(publicError.localizedDescription)
            let waiters = preparationWaiters
            preparationWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: publicError) }
            throw publicError
        }
    }

    public func status() -> RuntimeStatus {
        RuntimeStatus(
            state: state,
            pythonVersion: information?.pythonVersion,
            pythonImplementation: information?.implementation,
            platform: information?.platform,
            architecture: information?.architecture,
            sitePackagesDirectory: environment.sitePackagesDirectory,
            searchPaths: information?.searchPaths ?? configuredPaths,
            nativeBridgeVersion: nativeBridgeVersion,
            ytdlpInstalled: loadedYtdlpVersion != nil,
            ytdlpVersion: loadedYtdlpVersion,
            pluginCount: 0, pluginExtractorCount: 0, pluginPostProcessorCount: 0,
            jsChallengeProviders: [], requiredPluginsHealthy: false
        )
    }

    func ytdlpVersion() throws -> YtdlpVersion {
        guard state == .ready else { throw YtdlpKitError.invalidEnvironment("runtime is not ready") }
        let actual = try withGIL { try PythonBridge().ytdlpVersion() }
        loadedYtdlpVersion = actual
        return YtdlpVersion(string: actual)
    }

    func setLoadedYtdlpVersion(_ version: String) {
        loadedYtdlpVersion = version
    }

    func extractInfo(url: URL, optionsJSON: String) throws -> YtdlpMediaInfo {
        guard state == .ready else { throw YtdlpKitError.invalidEnvironment("runtime is not ready") }
        return try withGIL {
            try YtdlpBridge.decodeExtraction(
                PythonBridge().extract(url: url.absoluteString, optionsJSON: optionsJSON)
            )
        }
    }

    func download(request: YtdlpRequest, optionsJSON: String, operationID: UUID) throws -> YtdlpDownloadResult {
        guard state == .ready else { throw YtdlpKitError.invalidEnvironment("runtime is not ready") }
        return try withGIL {
            let json = try PythonBridge().download(
                url: request.url.absoluteString, optionsJSON: optionsJSON,
                operationID: operationID.uuidString,
                outputDirectory: request.outputDirectory.path
            )
            return try YtdlpBridge.decodeDownload(json, outputDirectory: request.outputDirectory)
        }
    }

    func testYtdlpCallbacks(operationID: UUID) throws -> String {
        try withGIL {
            try PythonBridge().testYtdlpCallbacks(operationID: operationID.uuidString)
        }
    }

    func testFFmpegBridge() throws -> String {
        try withGIL { try PythonBridge().ffmpegBridgeStatus() }
    }

    func testFFmpegMerge(video: URL, audio: URL, output: URL, operationID: UUID) throws -> String {
        try withGIL {
            try PythonBridge().ffmpegBridgeMerge(
                video: video.path, audio: audio.path, output: output.path,
                operationID: operationID.uuidString)
        }
    }

    func inspectWheel(_ url: URL) throws -> WheelInspection {
        try withGIL { try WheelInspector.decodeInspection(PythonBridge().inspectWheel(url)) }
    }

    func extractWheel(_ wheel: URL, to destination: URL, stripNative: Bool) throws -> [String] {
        try withGIL {
            try WheelInspector.decodeExtraction(
                PythonBridge().extractWheel(wheel, to: destination, stripNative: stripNative)
            )
        }
    }

    func addPackagePath(_ url: URL) throws {
        try withGIL { try PythonBridge().addPackagePath(url) }
    }

    func removePackagePath(_ url: URL) throws {
        try withGIL { try PythonBridge().removePackagePath(url) }
    }

    func validateImports(_ modules: [String]) throws {
        try withGIL { try PythonBridge().validateImports(modules) }
    }

    func parseRequirement(_ requirement: String, environmentJSON: String) throws -> String {
        try withGIL {
            try PythonBridge().parseRequirement(requirement, environmentJSON: environmentJSON)
        }
    }

    func selectVersion(_ versions: [String], specifier: String,
                       allowPrereleases: Bool) throws -> String {
        try withGIL {
            try PythonBridge().selectVersion(
                versions, specifier: specifier, allowPrereleases: allowPrereleases
            )
        }
    }

    func pluginInventory(refresh: Bool) throws -> String {
        try withGIL { try PythonBridge().pluginInventory(refresh: refresh) }
    }

    func matchingExtractors(url: URL) throws -> String {
        try withGIL { try PythonBridge().matchingExtractors(url: url.absoluteString) }
    }

    private func withGIL<T>(_ body: () throws -> T) rethrows -> T {
        let state = YtdlpKit2_AcquireGIL()
        defer { YtdlpKit2_ReleaseGIL(state) }
        return try body()
    }
}
