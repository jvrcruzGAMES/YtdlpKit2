import CryptoKit
import Foundation

struct ResolvedPackageArtifact: Sendable {
    let name: String
    let version: String
    let url: URL
    let sha256: String
    let filename: String
    let source: PackageSource
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

    func resolve(name: String, exactVersion: String? = nil) async throws -> ResolvedPackageArtifact {
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
        guard let file = files.first(where: {
            !$0.yanked && $0.packagetype == "bdist_wheel"
                && $0.filename.hasSuffix("-py3-none-any.whl")
        }) ?? files.first(where: {
            !$0.yanked && $0.packagetype == "bdist_wheel"
                && $0.filename.hasSuffix("-py2.py3-none-any.whl")
        }) else {
            throw PackageManagerError.nativeBinaryUnavailable(
                "No compatible pure-Python wheel for \(project.info.name) \(version)"
            )
        }
        return .init(name: project.info.name, version: version, url: file.url,
                     sha256: file.digests.sha256, filename: file.filename, source: .pypi)
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
