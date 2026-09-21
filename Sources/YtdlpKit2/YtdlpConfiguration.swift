import Foundation

public struct YtdlpConfiguration: Sendable {
    public var verboseLogging: Bool
    public var applicationSupportDirectory: URL?
    public var additionalPythonPaths: [URL]
    public var additionalPluginDirectories: [URL]
    public var maximumConcurrentMediaOperations: Int

    public init(
        verboseLogging: Bool = false,
        applicationSupportDirectory: URL? = nil,
        additionalPythonPaths: [URL] = [],
        additionalPluginDirectories: [URL] = [],
        maximumConcurrentMediaOperations: Int = 1
    ) {
        self.verboseLogging = verboseLogging
        self.applicationSupportDirectory = applicationSupportDirectory
        self.additionalPythonPaths = additionalPythonPaths
        self.additionalPluginDirectories = additionalPluginDirectories
        self.maximumConcurrentMediaOperations = max(1, maximumConcurrentMediaOperations)
    }
}
