import Foundation

/// Structured package resolution and transaction failures.
public enum PackageManagerError: Error, LocalizedError, Sendable, Equatable {
    case packageNotFound(String), versionNotFound(String), dependencyConflict(String)
    case incompatiblePython(String), incompatiblePlatform(String)
    case nativeBinaryUnavailable(String), nativeVersionMismatch(String)
    case unsupportedBuildBackend(String), unsupportedGitSource(String)
    case hashMismatch(String), installationFailed(String), rollbackFailed(String)
    case protectedPackage(String), invalidRequirement(String)

    public var errorDescription: String? {
        switch self {
        case let .packageNotFound(v): "Package not found: \(v)"
        case let .versionNotFound(v): "Package version not found: \(v)"
        case let .dependencyConflict(v): "Dependency conflict: \(v)"
        case let .incompatiblePython(v): "Incompatible Python: \(v)"
        case let .incompatiblePlatform(v): "Incompatible platform: \(v)"
        case let .nativeBinaryUnavailable(v): "Bundled native binary unavailable: \(v)"
        case let .nativeVersionMismatch(v): "Bundled native version mismatch: \(v)"
        case let .unsupportedBuildBackend(v): "Unsupported build backend: \(v)"
        case let .unsupportedGitSource(v): "Unsupported Git source: \(v)"
        case let .hashMismatch(v): "Package hash mismatch: \(v)"
        case let .installationFailed(v): "Package installation failed: \(v)"
        case let .rollbackFailed(v): "Package rollback failed: \(v)"
        case let .protectedPackage(v): "Managed core package cannot be removed: \(v)"
        case let .invalidRequirement(v): "Invalid package requirement: \(v)"
        }
    }
}
