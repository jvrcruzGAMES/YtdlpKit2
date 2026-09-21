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
}
