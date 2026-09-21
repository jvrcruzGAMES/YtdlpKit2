import Foundation

public actor YtdlpPluginManager {
    private let configuration: YtdlpConfiguration
    private let packages: YtdlpPackageManager
    private var cached: [InstalledPlugin]?
    private var lastDiagnostics = PluginScanDiagnostics(scanErrors: [], searchPaths: [])

    init(configuration: YtdlpConfiguration, packages: YtdlpPackageManager) {
        self.configuration = configuration
        self.packages = packages
    }

    public func installedPlugins() async throws -> [InstalledPlugin] {
        if let cached { return cached }
        return try await scan(refresh: false)
    }

    @discardableResult
    public func refresh() async throws -> [InstalledPlugin] {
        cached = nil
        return try await scan(refresh: true)
    }

    public func plugin(named name: String) async throws -> InstalledPlugin? {
        let key = PackageName.normalize(name)
        return try await installedPlugins().first {
            $0.id == name || PackageName.normalize($0.distributionName ?? $0.displayName) == key
        }
    }

    public func install(_ requirement: PackageRequirement) async throws -> InstalledPlugin {
        let package = try await packages.install(requirement)
        let inventory = try await refresh()
        guard let plugin = inventory.first(where: {
            PackageName.normalize($0.distributionName ?? "") == package.normalizedName
        }) else { throw PluginManagerError.packageContainsNoPlugin(package.name) }
        return plugin
    }

    public func uninstall(_ plugin: InstalledPlugin) async throws {
        if plugin.isRequired { throw PluginManagerError.requiredPluginCannotBeRemoved(plugin.displayName) }
        guard plugin.isManaged, let distribution = plugin.distributionName else {
            throw PluginManagerError.unmanagedPlugin(plugin.displayName)
        }
        try await packages.uninstall(distribution)
        _ = try await refresh()
    }

    public func pluginExtractors() async throws -> [YtdlpPluginExtractor] {
        try await installedPlugins().flatMap(\.capabilities).compactMap {
            if case let .extractor(value) = $0 { value } else { nil }
        }
    }

    public func pluginPostProcessors() async throws -> [YtdlpPluginPostProcessor] {
        try await installedPlugins().flatMap(\.capabilities).compactMap {
            if case let .postProcessor(value) = $0 { value } else { nil }
        }
    }

    public func javaScriptChallengeProviders() async throws -> [YtdlpJSChallengeProvider] {
        try await installedPlugins().flatMap(\.capabilities).compactMap {
            if case let .javaScriptChallengeProvider(value) = $0 { value } else { nil }
        }
    }

    public func extractors(matchingURL url: URL) async throws -> [YtdlpExtractorDescriptor] {
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        let json = try await runtime.matchingExtractors(url: url)
        let values = try decoder.decode([RawMatch].self, from: Data(json.utf8))
        let pluginsByModule = Dictionary(uniqueKeysWithValues: try await installedPlugins().flatMap {
            plugin in plugin.moduleNames.map { ($0, plugin.id) }
        })
        return values.map { value in
            let owner = pluginsByModule.first { value.extractor.moduleName.hasPrefix($0.key) }?.value
            return YtdlpExtractorDescriptor(
                extractor: value.extractor.extractor,
                source: owner.map(YtdlpExtractorSource.plugin) ?? .builtin,
                isGenericFallback: value.generic
            )
        }
    }

    public func pluginSearchPaths() async throws -> [URL] {
        _ = try await installedPlugins()
        return lastDiagnostics.searchPaths
    }

    public func diagnostics() async throws -> PluginScanDiagnostics {
        _ = try await installedPlugins()
        return lastDiagnostics
    }

    func validateRequiredPlugins() async throws {
        let inventory = try await refresh()
        guard let plugin = inventory.first(where: {
            PackageName.normalize($0.distributionName ?? "") == "yt-dlp-apple-webkit-jsi"
        }) else { throw PluginManagerError.pluginLoadFailed("yt-dlp-apple-webkit-jsi was not discovered") }
        guard plugin.isLoaded else { throw PluginManagerError.pluginLoadFailed(plugin.loadErrors.joined(separator: "\n")) }
        guard plugin.capabilities.contains(where: {
            if case let .javaScriptChallengeProvider(provider) = $0 {
                return provider.name == "apple-webkit-jsi" && provider.available
            }
            return false
        }) else { throw PluginManagerError.providerUnavailable("apple-webkit-jsi") }
    }

    private func scan(refresh: Bool) async throws -> [InstalledPlugin] {
        do {
            let managed = try await packages.installedPackages()
            let byName = Dictionary(uniqueKeysWithValues: managed.map { ($0.normalizedName, $0) })
            let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
            let json = try await runtime.pluginInventory(refresh: refresh)
            let result = try decoder.decode(RawInventory.self, from: Data(json.utf8))
            let environment = try PythonEnvironment(baseDirectory: configuration.applicationSupportDirectory)
            let plugins = result.plugins.map { raw -> InstalledPlugin in
                let normalized = raw.distribution.map { PackageName.normalize($0.name) }
                let package = normalized.flatMap { byName[$0] }
                let errors = raw.errors
                let capabilities = raw.capabilities.map(\.model)
                let required = normalized == "yt-dlp-apple-webkit-jsi"
                let source: YtdlpPluginSource
                if let package {
                    switch package.source {
                    case .pypi: source = .managedPyPI
                    case .git: source = .managedGit
                    case .bundled: source = .managedBundled
                    case .local: source = .pythonNamespace
                    }
                } else if raw.capabilities.contains(where: {
                    ($0.value.origin ?? $0.value.metadata?["origin"] ?? "").hasPrefix(environment.pluginsDirectory.path)
                }) { source = .manualPluginPath }
                else { source = .pythonNamespace }
                let metadata = package.map {
                    YtdlpPluginMetadata(projectURL: $0.metadata.homePage,
                        description: $0.metadata.summary, author: $0.metadata.author,
                        license: $0.metadata.license, packageVersion: $0.version,
                        homepage: $0.metadata.homePage,
                        sourceRepository: $0.metadata.projectURLs["Repository"])
                }
                return InstalledPlugin(
                    id: raw.stableKey,
                    displayName: raw.distribution?.name ?? raw.modules.first ?? "Unknown plugin",
                    distributionName: raw.distribution?.name,
                    distributionVersion: raw.distribution?.version,
                    moduleNames: raw.modules, source: source, capabilities: capabilities,
                    isManaged: package != nil, isRequired: required,
                    isLoaded: errors.isEmpty && !capabilities.isEmpty,
                    activationState: errors.isEmpty ? .active : .failed,
                    health: errors.isEmpty ? .healthy : .broken(errors),
                    loadErrors: errors, metadata: metadata)
            }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            lastDiagnostics = PluginScanDiagnostics(
                scanErrors: result.scanErrors, searchPaths: result.pluginPaths.map(URL.init(fileURLWithPath:)))
            cached = plugins
            return plugins
        } catch let error as PluginManagerError { throw error }
        catch { throw PluginManagerError.pluginRefreshFailed(String(describing: error)) }
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder(); value.keyDecodingStrategy = .convertFromSnakeCase; return value
    }
}

private struct RawInventory: Decodable {
    let plugins: [RawPlugin]
    let scanErrors: [String]
    let pluginPaths: [String]
}
private struct RawPlugin: Decodable {
    let stableKey: String
    let distribution: RawDistribution?
    let modules: [String]
    let capabilities: [RawCapability]
    let errors: [String]
}
private struct RawDistribution: Decodable { let name: String; let version: String }
private struct RawCapability: Decodable {
    let kind: String
    let value: RawCapabilityValue
    var model: YtdlpPluginCapability {
        switch kind {
        case "extractor": return .extractor(value.extractor)
        case "postprocessor": return .postProcessor(value.postprocessor)
        case "java_script_challenge_provider": return .javaScriptChallengeProvider(value.provider)
        default: return .other(.init(kind: kind, name: value.name ?? value.className ?? kind,
                                     moduleName: value.moduleName, metadata: value.metadata ?? [:]))
        }
    }
}
private struct RawCapabilityValue: Decodable {
    let className: String?
    let moduleName: String
    let ieName: String?
    let description: String?
    let validURLPattern: String?
    let working: Bool?
    let ageLimit: Int?
    let supportsSearch: Bool?
    let origin: String?
    let registeredName: String?
    let name: String?
    let version: String?
    let providerKind: String?
    let available: Bool?
    let external: Bool?
    let metadata: [String: String]?
    var extractor: YtdlpPluginExtractor { .init(
        className: className ?? "", moduleName: moduleName, ieName: ieName,
        description: description, validURLPattern: validURLPattern, working: working,
        ageLimit: ageLimit, supportsSearch: supportsSearch ?? false, origin: origin) }
    var postprocessor: YtdlpPluginPostProcessor { .init(
        className: className ?? "", moduleName: moduleName,
        registeredName: registeredName ?? className ?? "", description: description, origin: origin) }
    var provider: YtdlpJSChallengeProvider { .init(
        name: name ?? "", version: version, moduleName: moduleName,
        providerKind: providerKind ?? "unknown", available: available ?? false,
        external: external ?? true, metadata: metadata ?? [:]) }
}
private struct RawMatch: Decodable {
    let extractor: RawCapabilityValue
    let plugin: Bool
    let generic: Bool
}
