import CryptoKit
import Foundation

/// Resolves GitHub source requirements to immutable, integrity-checked archives.
struct GitHubResolver: Sendable {
    private struct Commit: Decodable { let sha: String }

    let policy: PackageSecurityPolicy

    func resolve(url: URL, revision: String?) async throws -> ResolvedPackageArtifact {
        guard policy.allowGitHub, url.scheme == "https",
              url.host?.lowercased() == "github.com" else {
            throw PackageManagerError.unsupportedGitSource(url.absoluteString)
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else {
            throw PackageManagerError.unsupportedGitSource(url.absoluteString)
        }
        let owner = parts[0]
        let repository = parts[1].hasSuffix(".git")
            ? String(parts[1].dropLast(4)) : parts[1]
        guard !owner.isEmpty, !repository.isEmpty else {
            throw PackageManagerError.unsupportedGitSource(url.absoluteString)
        }
        let requested = revision ?? "HEAD"
        let encodedRevision = requested.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requested
        let commitURL = try endpoint("https://api.github.com/repos/\(owner)/\(repository)/commits/\(encodedRevision)")
        let commitData = try await request(commitURL)
        let commit = try JSONDecoder().decode(Commit.self, from: commitData)
        guard commit.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw PackageManagerError.installationFailed("GitHub returned an invalid commit identifier")
        }
        let archiveURL = try endpoint(
            "https://codeload.github.com/\(owner)/\(repository)/tar.gz/\(commit.sha)"
        )
        let archive = try await request(archiveURL)
        let hash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.temporaryDirectory
            .appending(path: "YtdlpKit2-git-\(UUID().uuidString).tar.gz")
        try archive.write(to: cache, options: .atomic)
        // Use a file URL so the verified bytes used to compute the digest are
        // exactly the bytes later copied into the managed artifact cache.
        return .init(
            name: repository, version: "0+git.\(commit.sha.prefix(12))", url: cache,
            sha256: hash, filename: "\(repository)-\(commit.sha).tar.gz",
            source: .git(url: url, revision: commit.sha), format: .sourceArchive,
            fallbackVersion: "0+git.\(commit.sha.prefix(12))"
        )
    }

    private func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw PackageManagerError.unsupportedGitSource(value)
        }
        return url
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("YtdlpKit2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PackageManagerError.installationFailed("GitHub returned HTTP \(code)")
        }
        return data
    }
}
