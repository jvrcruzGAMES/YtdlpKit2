import Foundation

public enum PythonRuntimeState: Sendable, Equatable {
    case uninitialized
    case starting
    case ready
    case failed(String)
    case shuttingDown
}

public struct RuntimeStatus: Sendable {
    public let state: PythonRuntimeState
    public let pythonVersion: String?
    public let pythonImplementation: String?
    public let platform: String?
    public let architecture: String?
    public let sitePackagesDirectory: URL
    public let searchPaths: [String]
    public let nativeBridgeVersion: String?
    public let ytdlpInstalled: Bool
    public let ytdlpVersion: String?
    public let pluginCount: Int
    public let pluginExtractorCount: Int
    public let pluginPostProcessorCount: Int
    public let jsChallengeProviders: [YtdlpJSChallengeProvider]
    public let requiredPluginsHealthy: Bool
    public var ffmpegAvailable: Bool = false
    public var ffprobeAvailable: Bool = false
    public var ffmpegVersion: String? = nil
    public var ffmpegKitNextVersion: String? = nil
    public var ffmpegBuildConfiguration: String? = nil
    public var hardwareAcceleration: [String] = []
}
