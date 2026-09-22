import CryptoKit
import Foundation

struct ResolvedPackageArtifact: Sendable {
    enum Format: Sendable { case wheel, sourceArchive }
    let name: String
    let version: String
    let url: URL
    let sha256: String
    let filename: String
    let source: PackageSource
    let format: Format
    let fallbackVersion: String?
}

private struct PyPIProject: Decodable {
    struct Info: Decodable { let name: String; let version: String }
    struct File: Decodable {
        struct Digests: Decodable { let sha256: String }
        let filename: String
        let url: URL
        let packagetype: String
        let yanked: Bool
        let digests: Digests
    }
    let info: Info
    let releases: [String: [File]]
}

struct PyPIResolver: Sendable {
    let policy: PackageSecurityPolicy

    func resolve(name: String, exactVersion: String? = nil,
                 allowBundledNativeWheel: Bool = false) async throws -> ResolvedPackageArtifact {
        guard policy.allowPyPI else { throw PackageManagerError.incompatiblePlatform("PyPI is disabled") }
        let normalized = PackageName.normalize(name)
        if let allowed = policy.allowedPackageNames,
           !allowed.map(PackageName.normalize).contains(normalized) {
            throw PackageManagerError.packageNotFound("\(name) is not allowed by policy")
        }
        guard let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://pypi.org/pypi/\(escaped)/json") else {
            throw PackageManagerError.invalidRequirement(name)
        }
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else {
            throw PackageManagerError.packageNotFound(name)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw PackageManagerError.packageNotFound(name) }
            throw PackageManagerError.installationFailed("PyPI returned HTTP \(http.statusCode)")
        }
        let project = try JSONDecoder().decode(PyPIProject.self, from: data)
        let version = exactVersion ?? project.info.version
        guard let files = project.releases[version] else {
            throw PackageManagerError.versionNotFound("\(name) \(version)")
        }
        // Runtime installation currently accepts universal pure-Python wheels.
        // Platform wheels are considered only through the native registry path.
        let purePython = files.first(where: {
            !$0.yanked && $0.packagetype == "bdist_wheel"
                && $0.filename.hasSuffix("-py3-none-any.whl")
        }) ?? files.first(where: {
            !$0.yanked && $0.packagetype == "bdist_wheel"
                && $0.filename.hasSuffix("-py2.py3-none-any.whl")
        })
        // A package whose executable portion is already signed into the app
        // still needs its wheel metadata/Python files installed in the managed
        // package root. The wheel's native members are discarded later and the
        // bundled frameworks remain the only executable implementation.
        let bundledNative = allowBundledNativeWheel ? files
            .filter { !$0.yanked && $0.packagetype == "bdist_wheel" }
            .sorted { nativeWheelPreference($0.filename) < nativeWheelPreference($1.filename) }
            .first : nil
        guard let file = allowBundledNativeWheel ? bundledNative : purePython else {
            throw PackageManagerError.nativeBinaryUnavailable(
                "No compatible pure-Python wheel for \(project.info.name) \(version)"
            )
        }
        return .init(name: project.info.name, version: version, url: file.url,
                     sha256: file.digests.sha256, filename: file.filename, source: .pypi,
                     format: .wheel, fallbackVersion: nil)
    }

    private func nativeWheelPreference(_ filename: String) -> Int {
        if filename.contains("macosx") && filename.contains("universal2") { return 0 }
        if filename.contains("macosx") { return 1 }
        if filename.contains("ios") { return 2 }
        return 3
    }

    func versions(name: String) async throws -> [String] {
        let project = try await project(named: name)
        return Array(project.releases.keys)
    }

    private func project(named name: String) async throws -> PyPIProject {
        let normalized = PackageName.normalize(name)
        guard let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://pypi.org/pypi/\(escaped)/json") else {
            throw PackageManagerError.invalidRequirement(name)
        }
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PackageManagerError.packageNotFound(name)
        }
        return try JSONDecoder().decode(PyPIProject.self, from: data)
    }
}

struct PackageArtifactCache: Sendable {
    let directory: URL

    func download(_ artifact: ResolvedPackageArtifact) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(artifact.sha256)-\(artifact.filename)")
        if let existing = try? Data(contentsOf: destination), digest(existing) == artifact.sha256 {
            return destination
        }
        if artifact.url.isFileURL {
            let data = try Data(contentsOf: artifact.url)
            defer { try? FileManager.default.removeItem(at: artifact.url) }
            guard digest(data) == artifact.sha256 else {
                throw PackageManagerError.hashMismatch(artifact.filename)
            }
            try data.write(to: destination, options: .atomic)
            return destination
        }
        let (data, response) = try await URLSession.shared.data(from: artifact.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PackageManagerError.installationFailed("Artifact download failed: \(artifact.url)")
        }
        guard digest(data) == artifact.sha256 else {
            throw PackageManagerError.hashMismatch(artifact.filename)
        }
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
