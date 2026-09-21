import Foundation

public enum PluginManagerError: LocalizedError, Sendable {
    case requiredPluginCannotBeRemoved(String)
    case packageContainsNoPlugin(String)
    case pluginLoadFailed(String)
    case pluginRefreshFailed(String)
    case providerUnavailable(String)
    case unmanagedPlugin(String)

    public var errorDescription: String? {
        switch self {
        case let .requiredPluginCannotBeRemoved(name): "Required plugin cannot be removed: \(name)"
        case let .packageContainsNoPlugin(name): "Package installed but no yt-dlp plugin was found: \(name)"
        case let .pluginLoadFailed(message): "Plugin load failed: \(message)"
        case let .pluginRefreshFailed(message): "Plugin refresh failed: \(message)"
        case let .providerUnavailable(name): "Required JavaScript provider is unavailable: \(name)"
        case let .unmanagedPlugin(name): "Plugin is not owned by the package manager: \(name)"
        }
    }
}
