import Foundation
import Testing
@testable import YtdlpKit2

@Suite("Runtime foundation")
struct RuntimeFoundationTests {
    @Test("Runtime directories are created")
    func directories() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let environment = try PythonEnvironment(baseDirectory: base)
        try environment.createDirectories()
        for directory in environment.allDirectories {
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Manifest version validation rejects a mismatched interpreter")
    func manifestValidation() throws {
        let manifest = RuntimeManifest(
            runtimeVersion: 1,
            pythonVersion: "3.14.x",
            pythonABI: "cp314",
            ytdlpKitVersion: "0.1.0",
            platforms: ["macos"]
        )
        try manifest.validate(pythonVersion: "3.14.2")
        #expect(throws: YtdlpKitError.self) {
            try manifest.validate(pythonVersion: "3.13.9")
        }
    }

    @Test("Default managed packages live in Documents")
    func documentsDefault() throws {
        let documents = try #require(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first)
        let environment = try PythonEnvironment()
        #expect(environment.rootDirectory == documents.appending(
            path: "YtdlpKit2", directoryHint: .isDirectory
        ))
        #expect(environment.packagesDirectory.path.hasPrefix(documents.path + "/"))
    }

    @Test("Search paths are normalized and deduplicated")
    func paths() {
        var manager = PythonPathManager()
        manager.add(URL(fileURLWithPath: "/tmp/example/../example"))
        manager.add(URL(fileURLWithPath: "/tmp/example"))
        #expect(manager.strings.count == 1)
    }
}
