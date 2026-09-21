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

    public init(baseDirectory: URL? = nil) throws {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw YtdlpKitError.filesystemError("Application Support is unavailable")
            }
            base = applicationSupport
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
}
