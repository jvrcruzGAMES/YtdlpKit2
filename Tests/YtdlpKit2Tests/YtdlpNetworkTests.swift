import Foundation
import Testing
@testable import YtdlpKit2

/// Opt-in live tests. Set `YTDLPKIT_NETWORK_TEST_URL` to a stable direct-media
/// or extractor test URL after staging the CPython artifact.
@Suite("yt-dlp network integration", .serialized)
struct YtdlpNetworkTests {
    private static var testURL: URL? {
        ProcessInfo.processInfo.environment["YTDLPKIT_NETWORK_TEST_URL"].flatMap(URL.init(string:))
    }
    private static var enabled: Bool {
        testURL != nil && FileManager.default.fileExists(atPath: "Native/CPython/Python.xcframework")
    }
    private static var gitEnabled: Bool {
        ProcessInfo.processInfo.environment["YTDLPKIT_GIT_TEST"] == "1"
            && FileManager.default.fileExists(atPath: "Native/CPython/Python.xcframework")
    }

    @Test(
        "Extract metadata and perform a direct non-FFmpeg download",
        .enabled(if: Self.enabled, "Set YTDLPKIT_NETWORK_TEST_URL and stage CPython")
    )
    func extractAndDownload() async throws {
        let url = try #require(Self.testURL)
        let info = try await YtdlpKit.shared.extractInfo(from: url)
        #expect(info.id != nil)
        #expect(!info.formats.isEmpty)

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "YtdlpKit2-network-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try await YtdlpKit.shared.download(
            YtdlpRequest(url: url, outputDirectory: destination, format: .best)
        )
        #expect(!result.files.isEmpty)
        #expect(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(
        "GitHub pure-Python package installs its PyPI dependencies",
        .enabled(if: Self.gitEnabled, "Set YTDLPKIT_GIT_TEST=1 and stage CPython")
    )
    func gitDependencies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "YtdlpKit2-git-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = YtdlpPackageManager(configuration: .init(applicationSupportDirectory: root))
        let repository = try #require(URL(string: "https://github.com/pypa/sampleproject.git"))
        let package = try await manager.install(.git(repository))
        #expect(package.normalizedName == "sampleproject")
        #expect(package.source.gitRevision != nil)
        #expect(try await manager.package(named: "peppercorn")?.role == .ytdlpDependency)
    }
}

private extension PackageSource {
    var gitRevision: String? {
        if case let .git(_, revision) = self { return revision }
        return nil
    }
}
