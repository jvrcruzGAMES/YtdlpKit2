import Foundation
import Testing
@testable import YtdlpKit2

@Suite("Package manager foundation")
struct PackageManagerTests {
    @Test("PEP 503 project names normalize equivalently", arguments: [
        "Foo_Bar", "foo-bar", "foo.bar", "FOO---bar",
    ])
    func normalization(_ value: String) {
        #expect(PackageName.normalize(value) == "foo-bar")
    }

    @Test("Package sources preserve Git revision metadata")
    func sourceCoding() throws {
        let source = PackageSource.git(
            url: try #require(URL(string: "https://github.com/example/project.git")),
            revision: "v1.2.3"
        )
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(PackageSource.self, from: data) == source)
    }

    @Test("Native registry reports only the prepared native package versions")
    func nativeRegistry() throws {
        let registry = try NativePackageRegistry.bundled()
        for (name, version) in [
            ("Brotli", "1.2.0"),
            ("cffi", "2.0.0"),
            ("cryptography", "48.0.0"),
            ("curl-cffi", "0.16.2"),
            ("pycryptodomex", "3.21.0"),
        ] {
            #expect(registry.status(name: name, version: version) == .bundledCompatible)
        }
        #expect(registry.status(name: "cffi", version: "2.1.1") == .bundledVersionMismatch)
        #expect(registry.status(name: "unknown-native", version: "1.0") == .unavailable)
    }

    @Test("JSON database persists authoritative file ownership")
    func database() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try PackageDatabase(metadataDirectory: root)
        let metadata = PackageMetadata(
            name: "Example_Project", version: "1.0", summary: nil, author: nil,
            license: nil, requiresPython: nil, requiresDist: [], homePage: nil,
            projectURLs: [:], entryPoints: [], topLevelModules: ["example"]
        )
        let package = InstalledPackage(
            name: metadata.name, normalizedName: PackageName.normalize(metadata.name),
            version: metadata.version, source: .pypi, installDate: Date(timeIntervalSince1970: 1),
            installLocation: root.appending(path: "installed/example-project/1.0"),
            files: ["example/__init__.py"], dependencies: [], containsNativeCode: false,
            nativeKind: .purePython, nativeStatus: .notRequired, metadata: metadata,
            artifactSHA256: String(repeating: "a", count: 64), role: .userInstalled
        )
        try await database.record(package)
        let reopened = try PackageDatabase(metadataDirectory: root)
        #expect(await reopened.package(named: "example.project") == package)
        #expect(try await reopened.remove(named: "EXAMPLE_project") == package)
        #expect(await reopened.all().isEmpty)
    }
}
