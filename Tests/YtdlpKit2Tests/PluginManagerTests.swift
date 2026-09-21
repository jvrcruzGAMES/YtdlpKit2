import Foundation
import Testing
@testable import YtdlpKit2

@Suite("Plugin manager foundation")
struct PluginManagerTests {
    @Test("Plugin capability models preserve future-facing variants")
    func capabilityCoding() throws {
        let values: [YtdlpPluginCapability] = [
            .javaScriptChallengeProvider(.init(
                name: "apple-webkit-jsi", version: "0.1.1",
                moduleName: "yt_dlp_plugins.extractor.ytjsc",
                providerKind: "youtube-jsc", available: true, external: true,
                metadata: ["registry_key": "AppleWebKit"])),
            .other(.init(kind: "future-provider", name: "example",
                         moduleName: nil, metadata: [:])),
        ]
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([YtdlpPluginCapability].self, from: data) == values)
    }

    @Test("Required plugin removal has a useful error")
    func requiredError() {
        let error = PluginManagerError.requiredPluginCannotBeRemoved("apple-webkit-jsi")
        #expect(error.localizedDescription.contains("apple-webkit-jsi"))
    }
}
