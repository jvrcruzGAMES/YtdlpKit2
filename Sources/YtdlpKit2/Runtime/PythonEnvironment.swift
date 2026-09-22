import Foundation

public struct PythonEnvironment: Sendable {
    public let rootDirectory: URL
    public let runtimeDirectory: URL
    public let sitePackagesDirectory: URL
    public let packagesDirectory: URL
    public let pluginsDirectory: URL
    public let cacheDirectory: URL
    public let temporaryDirectory: URL
    public let metadataDirectory: URL
    public let logsDirectory: URL
    private let legacyRootDirectory: URL?

    public init(baseDirectory: URL? = nil) throws {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
            legacyRootDirectory = nil
        } else {
            guard let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else {
                throw YtdlpKitError.filesystemError("Documents directory is unavailable")
            }
            base = documents
            legacyRootDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first?.appending(path: "YtdlpKit2", directoryHint: .isDirectory)
        }

        rootDirectory = base.appending(path: "YtdlpKit2", directoryHint: .isDirectory)
        runtimeDirectory = rootDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        let python = rootDirectory.appending(path: "python", directoryHint: .isDirectory)
        sitePackagesDirectory = python.appending(path: "site-packages", directoryHint: .isDirectory)
        packagesDirectory = rootDirectory.appending(path: "packages", directoryHint: .isDirectory)
        pluginsDirectory = rootDirectory.appending(path: "plugins", directoryHint: .isDirectory)
        cacheDirectory = rootDirectory.appending(path: "cache", directoryHint: .isDirectory)
        temporaryDirectory = rootDirectory.appending(path: "temp", directoryHint: .isDirectory)
        metadataDirectory = rootDirectory.appending(path: "metadata", directoryHint: .isDirectory)
        logsDirectory = rootDirectory.appending(path: "logs", directoryHint: .isDirectory)
    }

    public func createDirectories() throws {
        do {
            if let legacyRootDirectory,
               FileManager.default.fileExists(atPath: legacyRootDirectory.path),
               !FileManager.default.fileExists(atPath: rootDirectory.path) {
                try FileManager.default.createDirectory(
                    at: rootDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: legacyRootDirectory, to: rootDirectory)
            }
            if let legacyRootDirectory,
               FileManager.default.fileExists(atPath: rootDirectory.path) {
                try rewritePackageDatabase(
                    replacing: legacyRootDirectory, with: rootDirectory
                )
            }
            for url in allDirectories {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } catch {
            throw YtdlpKitError.filesystemError(error.localizedDescription)
        }
    }

    var allDirectories: [URL] {
        [rootDirectory, runtimeDirectory, sitePackagesDirectory, packagesDirectory,
         pluginsDirectory, cacheDirectory, temporaryDirectory, metadataDirectory, logsDirectory]
    }

    private func rewritePackageDatabase(replacing oldRoot: URL, with newRoot: URL) throws {
        let database = newRoot.appending(path: "metadata/packages-v1.json")
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        let data = try Data(contentsOf: database)
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var packages = document["packages"] as? [String: Any] else { return }
        var changed = false
        for (key, value) in packages {
            guard var package = value as? [String: Any],
                  let location = package["installLocation"] as? String,
                  location.hasPrefix(oldRoot.absoluteString) else { continue }
            package["installLocation"] = newRoot.absoluteString
                + location.dropFirst(oldRoot.absoluteString.count)
            packages[key] = package
            changed = true
        }
        guard changed else { return }
        document["packages"] = packages
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: database, options: .atomic)
    }
}
