import Foundation

struct NativePackageManifest: Codable, Sendable {
    let nativeABI: Int
    let packages: [NativePackageDescriptor]
}

struct NativePackageRegistry: Sendable {
    let nativeABI: Int
    private let descriptors: [String: NativePackageDescriptor]

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "native-packages", withExtension: "json") else {
            throw PackageManagerError.installationFailed("native package manifest is missing")
        }
        let manifest = try JSONDecoder().decode(NativePackageManifest.self, from: Data(contentsOf: url))
        return Self(nativeABI: manifest.nativeABI, descriptors: Dictionary(
            uniqueKeysWithValues: manifest.packages.map { (PackageName.normalize($0.distributionName), $0) }
        ))
    }

    func descriptor(for name: String) -> NativePackageDescriptor? {
        descriptors[PackageName.normalize(name)]
    }

    func status(name: String, version: String, pythonABI: String = "cp314") -> NativePackageStatus {
        guard let descriptor = descriptor(for: name) else { return .unavailable }
        guard descriptor.version == version else { return .bundledVersionMismatch }
        guard descriptor.pythonABI == pythonABI else { return .unavailable }
        guard descriptor.supportedPlatforms.contains(Self.currentPlatform) else { return .unavailable }
        return .bundledCompatible
    }

    private static var currentPlatform: String {
        #if os(iOS) && targetEnvironment(simulator)
        #if arch(x86_64)
        return "ios-simulator-x86_64"
        #else
        return "ios-simulator-arm64"
        #endif
        #elseif os(iOS)
        return "ios-arm64"
        #elseif os(macOS) && arch(x86_64)
        return "macos-x86_64"
        #else
        return "macos-arm64"
        #endif
    }
}
