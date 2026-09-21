import Foundation

public struct RuntimeManifest: Codable, Sendable, Equatable {
    public let runtimeVersion: Int
    public let pythonVersion: String
    public let pythonABI: String
    public let ytdlpKitVersion: String
    public let platforms: [String]

    public init(runtimeVersion: Int, pythonVersion: String, pythonABI: String,
                ytdlpKitVersion: String, platforms: [String]) {
        self.runtimeVersion = runtimeVersion
        self.pythonVersion = pythonVersion
        self.pythonABI = pythonABI
        self.ytdlpKitVersion = ytdlpKitVersion
        self.platforms = platforms
    }

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "runtime-manifest", withExtension: "json") else {
            throw YtdlpKitError.runtimeNotFound
        }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw YtdlpKitError.incompatibleRuntime("Invalid runtime manifest: \(error)") }
    }

    public func validate(pythonVersion actual: String) throws {
        let expected = pythonVersion.split(separator: ".").prefix(2).joined(separator: ".")
        let found = actual.split(separator: ".").prefix(2).joined(separator: ".")
        guard expected == found else {
            throw YtdlpKitError.incompatibleRuntime("manifest requires Python \(expected); loaded \(actual)")
        }
    }
}
