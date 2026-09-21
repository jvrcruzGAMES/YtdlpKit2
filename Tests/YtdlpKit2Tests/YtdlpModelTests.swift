import Foundation
import Testing
@testable import YtdlpKit2

@Suite("yt-dlp models and fake bridge")
struct YtdlpModelTests {
    @Test("Media invocations preserve argv without shell quoting")
    func mediaArguments() throws {
        let values = ["-i", "/tmp/a file's 🎬 (final).mp4", "-c", "copy"]
        let invocation = FFmpegInvocation(operationID: UUID(), arguments: values)
        let decoded = try JSONDecoder().decode(
            FFmpegInvocation.self, from: JSONEncoder().encode(invocation))
        #expect(decoded.arguments == values)
    }

    @Test("Media bridge results use subprocess-compatible JSON keys")
    func mediaResultCoding() throws {
        let data = try JSONEncoder().encode(FFmpegExecutionResult(
            returnCode: 7, standardOutput: "out", standardError: "err"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["returncode"] as? Int == 7)
        #expect(object["stdout"] as? String == "out")
        #expect(object["stderr"] as? String == "err")
    }

    @Test("JSON values round-trip without Any")
    func jsonValue() throws {
        let value: JSONValue = .object([
            "name": .string("example"), "count": .number(3),
            "flags": .array([.bool(true), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("Progress prefers actual total and clamps fractions")
    func progress() {
        let progress = YtdlpDownloadProgress(
            status: "downloading", filename: nil, temporaryFilename: nil,
            downloadedBytes: 120, totalBytes: 100, estimatedTotalBytes: 200,
            speedBytesPerSecond: 10, eta: 0, elapsed: 12,
            fragmentIndex: nil, fragmentCount: nil
        )
        #expect(progress.fractionCompleted == 1)
    }

    @Test("Fake Python response decodes playlists, formats, and raw JSON")
    func fakeBridge() throws {
        let media: [String: Any] = [
            "id": "playlist", "title": "A playlist", "description": NSNull(),
            "webpageURL": "https://example.invalid/list", "originalURL": NSNull(),
            "extractor": "test", "extractorKey": "Test", "uploader": NSNull(),
            "uploaderID": NSNull(), "channel": NSNull(), "channelID": NSNull(),
            "duration": NSNull(), "timestamp": NSNull(), "uploadDate": NSNull(),
            "viewCount": NSNull(), "likeCount": NSNull(), "commentCount": NSNull(),
            "ageLimit": NSNull(), "liveStatus": NSNull(), "isLive": false,
            "wasLive": false, "thumbnailURL": NSNull(), "thumbnails": [],
            "formats": [["formatID": "18", "extension": "mp4", "videoCodec": "avc1",
                         "audioCodec": "aac"]],
            "subtitles": [], "automaticCaptions": [], "chapters": [],
            "playlistID": "playlist", "playlistTitle": "A playlist",
            "playlistIndex": NSNull(), "entries": [],
            "rawJSON": ["_type": "playlist", "future_field": [1, 2, 3]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "value": media])
        let decoded = try YtdlpBridge.decodeExtraction(String(decoding: data, as: UTF8.self))
        #expect(decoded.entries?.isEmpty == true)
        #expect(decoded.formats.first?.hasVideo == true)
        #expect(decoded.formats.first?.hasAudio == true)
        if case let .object(raw) = decoded.rawJSON {
            #expect(raw["future_field"] != nil)
        } else { Issue.record("raw JSON was not preserved") }
    }

    @Test("Pinned yt-dlp is downloaded, not bundled")
    func packageBoundary() {
        #expect(Bundle.main.url(forResource: "yt_dlp-2026.8.19-py3-none-any",
                                withExtension: "whl") == nil)
    }

    @Test("Native registry cancellation is keyed by operation ID")
    func cancellationRegistry() {
        let id = UUID()
        let stream = YtdlpOperationRegistry.shared.register(id)
        withExtendedLifetime(stream) {
            #expect(!YtdlpOperationRegistry.shared.isCancelled(id.uuidString))
            YtdlpOperationRegistry.shared.cancel(id.uuidString)
            #expect(YtdlpOperationRegistry.shared.isCancelled(id.uuidString))
        }
        YtdlpOperationRegistry.shared.finish(id)
    }
}
