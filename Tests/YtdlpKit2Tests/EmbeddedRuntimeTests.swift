import Foundation
import Testing
@testable import YtdlpKit2

#if os(iOS)
@Suite("iOS CPython standard library", .serialized)
struct IOSPythonStdlibTests {
    @Test("Default extension modules load from signed frameworks")
    func defaultExtensionModules() async throws {
        let runtime = try PythonRuntime(configuration: .init(
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)))
        try await runtime.prepare()
        #expect(await runtime.status().state == .ready)
    }
}
#endif

@Suite("Embedded CPython integration", .serialized)
struct EmbeddedRuntimeTests {
    private static var artifactIsStaged: Bool {
        #if os(iOS)
        return true
        #else
        FileManager.default.fileExists(atPath: "Native/CPython/Python.xcframework")
            && FileManager.default.fileExists(
                atPath: "Sources/YtdlpKit2/Resources/Runtime/python/lib/python3.14"
            )
        #endif
    }

    @Test(
        "FFmpegKitNext exposes in-process FFmpeg and FFprobe",
        .enabled(if: FileManager.default.fileExists(
            atPath: "Native/FFmpegKitNext/ffmpegkit.xcframework"),
            "FFmpegKitNext artifact is not staged")
    )
    func mediaBackend() async throws {
        let capabilities = try await YtdlpMediaProcessing().capabilities()
        #expect(capabilities.ffmpegAvailable)
        #expect(capabilities.ffprobeAvailable)
        #expect(capabilities.backendVersion == "9.0.0")
        #expect(capabilities.version?.contains("9.0.1") == true)

        let bridgeJSON = try await YtdlpKit.shared.testFFmpegBridge()
        let bridge = try #require(JSONSerialization.jsonObject(
            with: Data(bridgeJSON.utf8)) as? [String: Any])
        #expect(bridge["ffmpeg"] as? Bool == true)
        #expect(bridge["ffprobe"] as? Bool == true)
    }

    @Test(
        "FFmpegKitNext merges local audio and video and FFprobe parses the result",
        .enabled(if: FileManager.default.fileExists(
            atPath: "Native/FFmpegKitNext/ffmpegkit.xcframework"),
            "FFmpegKitNext artifact is not staged")
    )
    func mediaMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "video only 🎬.mp4")
        let audio = root.appending(path: "audio only.m4a")
        let output = root.appending(path: "merged (final).mp4")
        let provider = FFmpegKitMediaProcessingProvider()

        let videoResult = try await provider.executeFFmpeg(.init(
            operationID: UUID(), arguments: [
                "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1",
                "-an", "-c:v", "mpeg4", video.path,
            ]))
        #expect(videoResult.returnCode == 0)
        let audioResult = try await provider.executeFFmpeg(.init(
            operationID: UUID(), arguments: [
                "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-vn", "-c:a", "aac", audio.path,
            ]))
        #expect(audioResult.returnCode == 0)
        let mergedPath = try await YtdlpKit.shared.testFFmpegMerge(
            video: video, audio: audio, output: output)
        #expect(mergedPath == output.path)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let probe = try await provider.executeFFprobe(.init(
            operationID: UUID(), arguments: [
                "-v", "error", "-show_entries", "stream=codec_type",
                "-of", "json", output.path,
            ]))
        #expect(probe.returnCode == 0)
        let data = try #require(probe.standardOutput.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try #require(json["streams"] as? [[String: Any]])
        #expect(Set(streams.compactMap { $0["codec_type"] as? String }) == ["audio", "video"])
    }

    @Test(
        "An active FFmpegKitNext session can be cancelled",
        .enabled(if: FileManager.default.fileExists(
            atPath: "Native/FFmpegKitNext/ffmpegkit.xcframework"),
            "FFmpegKitNext artifact is not staged")
    )
    func mediaCancellation() async throws {
        let provider = FFmpegKitMediaProcessingProvider()
        let operationID = UUID()
        let execution = Task.detached {
            try await provider.executeFFmpeg(.init(operationID: operationID, arguments: [
                "-re", "-f", "lavfi", "-i", "testsrc=duration=5:size=64x64:rate=30",
                "-f", "null", "-",
            ]))
        }
        try await Task.sleep(for: .milliseconds(200))
        await provider.cancel(operationID: operationID)
        let result = try await execution.value
        #expect(result.cancelled)
    }

    @Test(
        "Real CPython and both bridge directions work",
        .enabled(if: Self.artifactIsStaged, "CPython artifact is not staged")
    )
    func runtime() async throws {
        let kit = YtdlpKit(configuration: .init(
            verboseLogging: true,
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
        ))
        try await kit.prepare()
        let status = await kit.runtimeStatus()
        #expect(status.state == .ready)
        #expect(status.pythonVersion?.hasPrefix("3.14.") == true)
        #expect(status.pythonImplementation == "CPython")
        #expect(status.nativeBridgeVersion == "1")
        #expect(status.searchPaths.contains(status.sitePackagesDirectory.path))
        #expect(status.ytdlpInstalled)
        #expect(status.ytdlpVersion == "2026.08.19")
        #expect(try await kit.ytdlpVersion().string == "2026.08.19")
    }

    @Test(
        "Concurrent and repeated preparation is idempotent",
        .enabled(if: Self.artifactIsStaged, "CPython artifact is not staged")
    )
    func concurrentPreparation() async throws {
        let kit = YtdlpKit.shared
        async let first: Void = kit.prepare()
        async let second: Void = kit.prepare()
        async let third: Void = kit.prepare()
        _ = try await (first, second, third)
        try await kit.prepare()
        #expect(await kit.runtimeStatus().state == .ready)
    }

    @Test(
        "Real yt-dlp errors cross the serialization boundary",
        .enabled(if: Self.artifactIsStaged, "CPython artifact is not staged")
    )
    func unsupportedURL() async throws {
        do {
            _ = try await YtdlpKit.shared.extractInfo(
                from: try #require(URL(string: "invalid-scheme://unit-test"))
            )
            Issue.record("Unsupported extraction unexpectedly succeeded")
        } catch is YtdlpError {
            // Any structured yt-dlp classification is acceptable here; the
            // assertion is that Python exceptions do not leak to consumers.
        }
    }

    @Test(
        "Real Python progress, logging, and cancellation callbacks reach Swift",
        .enabled(if: Self.artifactIsStaged, "CPython artifact is not staged")
    )
    func nativeCallbacks() async throws {
        let kit = YtdlpKit.shared
        try await kit.prepare()
        let id = UUID()
        let stream = YtdlpOperationRegistry.shared.register(id)
        #expect(try await kit.testYtdlpCallbacks(operationID: id) == "ok")
        YtdlpOperationRegistry.shared.finish(id)
        var sawProgress = false
        var sawWarning = false
        for await event in stream {
            if case .progress = event { sawProgress = true }
            if case .warning = event { sawWarning = true }
        }
        #expect(sawProgress)
        #expect(sawWarning)

        let cancelledID = UUID()
        let cancelledStream = YtdlpOperationRegistry.shared.register(cancelledID)
        _ = cancelledStream
        YtdlpOperationRegistry.shared.cancel(cancelledID.uuidString)
        #expect(try await kit.testYtdlpCallbacks(operationID: cancelledID) == "cancelled")
        YtdlpOperationRegistry.shared.finish(cancelledID)
    }

    @Test(
        "General package manager installs and safely uninstalls a pure wheel",
        .enabled(if: Self.artifactIsStaged, "CPython artifact is not staged")
    )
    func packageLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = YtdlpKit(configuration: .init(applicationSupportDirectory: root))
        try await kit.prepare()
        let core = try await kit.packages.installedPackages()
        #expect(core.contains { $0.normalizedName == "packaging" })
        #expect(core.contains {
            $0.normalizedName == "certifi" && $0.role == .runtimeCore
        })
        for (name, version) in [
            ("packaging", "26.3"),
            ("charset-normalizer", "3.5.1"),
            ("idna", "3.20"),
            ("mutagen", "1.48.1"),
            ("requests", "2.34.2"),
            ("urllib3", "2.8.0"),
            ("websockets", "17.1"),
        ] {
            #expect(core.contains {
                $0.normalizedName == name && $0.version == version && $0.role == .runtimeCore
            })
        }
        #expect(core.contains { $0.normalizedName == "yt-dlp" })
        #expect(core.contains { $0.normalizedName == "yt-dlp-ejs" })
        #expect(core.contains { $0.normalizedName == "yt-dlp-apple-webkit-jsi" })

        let plugins = try await kit.plugins.installedPlugins()
        let webkit = try #require(plugins.first {
            $0.distributionName.map(PackageName.normalize) == "yt-dlp-apple-webkit-jsi"
        })
        #expect(webkit.isManaged)
        #expect(webkit.isRequired)
        #expect(webkit.isLoaded)
        #expect(webkit.capabilities.contains {
            if case let .javaScriptChallengeProvider(provider) = $0 {
                return provider.name == "apple-webkit-jsi" && provider.available
            }
            return false
        })
        await #expect(throws: PluginManagerError.self) {
            try await kit.plugins.uninstall(webkit)
        }

        let installed = try await kit.packages.install(.pypiVersion("tomli", "2.2.1"))
        #expect(installed.normalizedName == "tomli")
        #expect(installed.version == "2.2.1")
        #expect(installed.nativeStatus == .notRequired)
        #expect(FileManager.default.fileExists(atPath: installed.installLocation.path))
        #expect(FileManager.default.fileExists(
            atPath: installed.installLocation.appending(path: "tomli").path
        ))
        let updated = try await kit.packages.update("tomli")
        #expect(updated.normalizedName == "tomli")
        #expect(try await kit.packages.package(named: "tomli")?.version == updated.version)
        let constrained = try await kit.packages.install(.pep508("tomli>=2,<3"))
        #expect(constrained.version == updated.version)
        try await kit.packages.uninstall("TOMLI")
        #expect(try await kit.packages.package(named: "tomli") == nil)
        #expect(FileManager.default.fileExists(atPath: installed.installLocation.path))
        #expect(!FileManager.default.fileExists(
            atPath: installed.installLocation.appending(path: "tomli").path
        ))

        // ada-url is unbundled and contains native code; installing it must be rejected under bundledOnly policy.
        do {
            _ = try await kit.packages.install(.pypiVersion("ada-url", "4.0.0"))
            Issue.record("Expected native binary unavailable error for unbundled ada-url")
        } catch let PackageManagerError.nativeBinaryUnavailable(name) {
            #expect(name.contains("ada-url") || name.contains("ada_url"))
        }

        // hanime-plugin remains an opt-in user plugin. Its native
        // dependency (pycryptodomex) resolves to the bundled implementation,
        // and refresh must register HanimeTVIE ahead of GenericIE.
        let hanime = try await kit.plugins.install(
            .pypiVersion("hanime-plugin", "2026.9.27")
        )
        #expect(hanime.source == .managedPyPI)
        #expect(hanime.isLoaded)
        let pycryptodome = try #require(await kit.packages.package(named: "pycryptodomex"))
        #expect(pycryptodome.version == "3.23.0")
        #expect(pycryptodome.nativeStatus == .bundledCompatible)
        #expect(pycryptodome.role == .ytdlpDependency)
        let matches = try await kit.plugins.extractors(matchingURL: URL(
            string: "https://hanime.tv/videos/hentai/fuzzy-lips-1"
        )!)
        #expect(matches.contains {
            $0.source == .plugin(hanime.id) && $0.extractor.className == "HanimeTVIE"
        })
        let hstreamMatches = try await kit.plugins.extractors(matchingURL: URL(
            string: "https://hstream.moe/hentai/harem-tou-e-youkoso-1"
        )!)
        #expect(hstreamMatches.first?.extractor.className == "HstreamIE")
        #expect(hstreamMatches.first?.source == .plugin(hanime.id))
        try await kit.plugins.uninstall(hanime)

        await #expect(throws: PackageManagerError.self) {
            try await kit.packages.uninstall("packaging")
        }
    }
}
