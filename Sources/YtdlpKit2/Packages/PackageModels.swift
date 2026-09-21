import Foundation

/// A Python distribution requirement accepted by the package manager.
public enum PackageRequirement: Sendable, Hashable {
    case pypi(String)
    case pypiVersion(String, String)
    case pep508(String)
    case git(URL)
    case gitRevision(URL, String)
}

/// The persisted origin of an installed Python distribution.
public enum PackageSource: Sendable, Codable, Hashable {
    case pypi
    case git(url: URL, revision: String?)
    case bundled
    case local
}

/// Relationship between a distribution and signed native components.
public enum PackageNativeKind: String, Sendable, Codable, Hashable {
    case purePython
    case bundledNative
    case unsupportedNative
}

/// Runtime compatibility of a package's native portion.
public enum NativePackageStatus: String, Sendable, Codable, Hashable {
    case notRequired
    case bundledCompatible
    case bundledVersionMismatch
    case unavailable
}

/// Package role used to protect runtime-critical distributions.
public enum ManagedPackageRole: String, Sendable, Codable, Hashable {
    case runtimeCore
    case ytdlpDependency
    case userInstalled
}

/// A distribution entry point read from `entry_points.txt`.
public struct PackageEntryPoint: Sendable, Codable, Hashable {
    public let group: String
    public let name: String
    public let value: String
}

/// Metadata read from a wheel's `.dist-info` directory.
public struct PackageMetadata: Sendable, Codable, Hashable {
    public let name: String
    public let version: String
    public let summary: String?
    public let author: String?
    public let license: String?
    public let requiresPython: String?
    public let requiresDist: [String]
    public let homePage: URL?
    public let projectURLs: [String: URL]
    public let entryPoints: [PackageEntryPoint]
    public let topLevelModules: [String]
}

/// Authoritative inventory record for a managed Python distribution.
public struct InstalledPackage: Sendable, Codable, Hashable {
    public let name: String
    public let normalizedName: String
    public let version: String
    public let source: PackageSource
    public let installDate: Date
    public let installLocation: URL
    public let files: [String]
    public let dependencies: [String]
    public let containsNativeCode: Bool
    public let nativeKind: PackageNativeKind
    public let nativeStatus: NativePackageStatus
    public let metadata: PackageMetadata
    public let artifactSHA256: String
    public let role: ManagedPackageRole
}

/// Native extension support compiled and signed into YtdlpKit2.
public struct NativePackageDescriptor: Sendable, Codable, Hashable {
    public let distributionName: String
    public let version: String
    public let pythonABI: String
    public let supportedPlatforms: [String]
    public let modules: [String]
    public let libraries: [String]
    public let buildIdentifier: String
}

/// Policy for downloaded artifacts containing executable code.
public enum BinaryPackagePolicy: Sendable, Codable, Hashable {
    case bundledOnly
    case rejectAllNative
}

/// Network and trust restrictions for package resolution.
public struct PackageSecurityPolicy: Sendable, Hashable {
    public var allowPyPI: Bool
    public var allowGitHub: Bool
    public var allowedGitHosts: Set<String>
    public var allowedPackageNames: Set<String>?
    public var requireHashes: Bool
    public var allowPrereleases: Bool
    public var binaryPolicy: BinaryPackagePolicy

    public init(allowPyPI: Bool = true, allowGitHub: Bool = true,
                allowedGitHosts: Set<String> = ["github.com"],
                allowedPackageNames: Set<String>? = nil, requireHashes: Bool = true,
                allowPrereleases: Bool = false,
                binaryPolicy: BinaryPackagePolicy = .bundledOnly) {
        self.allowPyPI = allowPyPI; self.allowGitHub = allowGitHub
        self.allowedGitHosts = allowedGitHosts; self.allowedPackageNames = allowedPackageNames
        self.requireHashes = requireHashes; self.allowPrereleases = allowPrereleases
        self.binaryPolicy = binaryPolicy
    }
}

/// Progress emitted while resolving and installing a distribution.
public enum PackageInstallEvent: Sendable, Hashable {
    case resolving(String)
    case downloading(String, Double?)
    case verifying(String)
    case building(String)
    case installing(String)
    case validating(String)
    case completed(InstalledPackage)
}

/// Machine-readable package-manager and native ABI diagnostics.
public struct PackageManagerDiagnostics: Sendable, Codable, Hashable {
    public let ready: Bool
    public let nativeABI: Int
    public let installedPackages: [InstalledPackage]
}
