import Foundation

public enum YtdlpPluginSource: String, Sendable, Codable, Hashable {
    case managedPyPI, managedGit, managedBundled, manualPluginPath, pythonNamespace, unknown
}

public enum PluginActivationState: String, Sendable, Codable, Hashable {
    case active, installedPendingReload, failed
}

public enum YtdlpPluginHealth: Sendable, Codable, Hashable {
    case healthy
    case degraded([String])
    case broken([String])
    case pendingRuntimeReload
}

public struct YtdlpPluginExtractor: Sendable, Codable, Hashable {
    public let className: String
    public let moduleName: String
    public let ieName: String?
    public let description: String?
    public let validURLPattern: String?
    public let working: Bool?
    public let ageLimit: Int?
    public let supportsSearch: Bool
    public let origin: String?
}

public struct YtdlpPluginPostProcessor: Sendable, Codable, Hashable {
    public let className: String
    public let moduleName: String
    public let registeredName: String
    public let description: String?
    public let origin: String?
}

public struct YtdlpJSChallengeProvider: Sendable, Codable, Hashable {
    public let name: String
    public let version: String?
    public let moduleName: String
    public let providerKind: String
    public let available: Bool
    public let external: Bool
    public let metadata: [String: String]
}

public struct YtdlpPluginDownloader: Sendable, Codable, Hashable {
    public let name: String
    public let moduleName: String
}

public struct YtdlpPluginGenericCapability: Sendable, Codable, Hashable {
    public let kind: String
    public let name: String
    public let moduleName: String?
    public let metadata: [String: String]
}

public enum YtdlpPluginCapability: Sendable, Codable, Hashable {
    case extractor(YtdlpPluginExtractor)
    case postProcessor(YtdlpPluginPostProcessor)
    case javaScriptChallengeProvider(YtdlpJSChallengeProvider)
    case downloader(YtdlpPluginDownloader)
    case other(YtdlpPluginGenericCapability)
}

public struct YtdlpPluginMetadata: Sendable, Codable, Hashable {
    public let projectURL: URL?
    public let description: String?
    public let author: String?
    public let license: String?
    public let packageVersion: String?
    public let homepage: URL?
    public let sourceRepository: URL?
}

public struct InstalledPlugin: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let distributionName: String?
    public let distributionVersion: String?
    public let moduleNames: [String]
    public let source: YtdlpPluginSource
    public let capabilities: [YtdlpPluginCapability]
    public let isManaged: Bool
    public let isRequired: Bool
    public let isLoaded: Bool
    public let activationState: PluginActivationState
    public let health: YtdlpPluginHealth
    public let loadErrors: [String]
    public let metadata: YtdlpPluginMetadata?
}

public enum YtdlpExtractorSource: Sendable, Codable, Hashable {
    case builtin
    case plugin(String)
}

public struct YtdlpExtractorDescriptor: Sendable, Codable, Hashable {
    public let extractor: YtdlpPluginExtractor
    public let source: YtdlpExtractorSource
    public let isGenericFallback: Bool
}

public struct PluginScanDiagnostics: Sendable, Codable, Hashable {
    public let scanErrors: [String]
    public let searchPaths: [URL]
}
