import Foundation

public struct MediaProcessingCapabilities: Sendable, Codable, Hashable {
    public let ffmpegAvailable: Bool
    public let ffprobeAvailable: Bool
    public let version: String?
    public let backendVersion: String?
    public let supportedProtocols: [String]
    public let supportedFormats: [String]
    public let supportedCodecs: [String]
    public let hardwareAcceleration: [String]
    public let videoToolboxAvailable: Bool
    public let buildConfiguration: String?

    public init(ffmpegAvailable: Bool, ffprobeAvailable: Bool, version: String? = nil,
                backendVersion: String? = nil, supportedProtocols: [String] = [],
                supportedFormats: [String] = [], supportedCodecs: [String] = [],
                hardwareAcceleration: [String] = [], videoToolboxAvailable: Bool = false,
                buildConfiguration: String? = nil) {
        self.ffmpegAvailable = ffmpegAvailable; self.ffprobeAvailable = ffprobeAvailable
        self.version = version; self.backendVersion = backendVersion
        self.supportedProtocols = supportedProtocols; self.supportedFormats = supportedFormats
        self.supportedCodecs = supportedCodecs; self.hardwareAcceleration = hardwareAcceleration
        self.videoToolboxAvailable = videoToolboxAvailable
        self.buildConfiguration = buildConfiguration
    }
}

public struct FFmpegInvocation: Sendable, Codable, Hashable {
    public let operationID: UUID
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]

    public init(operationID: UUID, arguments: [String], workingDirectory: URL? = nil,
                environment: [String: String] = [:]) {
        self.operationID = operationID; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.environment = environment
    }
}

public typealias FFprobeInvocation = FFmpegInvocation

public struct FFmpegExecutionResult: Sendable, Codable, Hashable {
    public let returnCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let cancelled: Bool

    public init(returnCode: Int32, standardOutput: String = "", standardError: String = "",
                cancelled: Bool = false) {
        self.returnCode = returnCode; self.standardOutput = standardOutput
        self.standardError = standardError; self.cancelled = cancelled
    }

    enum CodingKeys: String, CodingKey {
        case returnCode = "returncode"
        case standardOutput = "stdout"
        case standardError = "stderr"
        case cancelled
    }
}

public typealias FFprobeExecutionResult = FFmpegExecutionResult

public protocol MediaProcessingProvider: Sendable {
    var isAvailable: Bool { get async }
    func capabilities() async throws -> MediaProcessingCapabilities
    func executeFFmpeg(_ invocation: FFmpegInvocation) async throws -> FFmpegExecutionResult
    func executeFFprobe(_ invocation: FFprobeInvocation) async throws -> FFprobeExecutionResult
    func cancel(operationID: UUID) async
}

public struct YtdlpMediaProcessing: Sendable {
    public init() {}
    public func capabilities() async throws -> MediaProcessingCapabilities {
        try await MediaProcessingCenter.shared.capabilities()
    }
}

struct UnavailableMediaProcessingProvider: MediaProcessingProvider {
    var isAvailable: Bool { get async { false } }
    func capabilities() async throws -> MediaProcessingCapabilities {
        .init(ffmpegAvailable: false, ffprobeAvailable: false)
    }
    func executeFFmpeg(_ invocation: FFmpegInvocation) async throws -> FFmpegExecutionResult {
        throw MediaProcessingError.ffmpegUnavailable
    }
    func executeFFprobe(_ invocation: FFprobeInvocation) async throws -> FFprobeExecutionResult {
        throw MediaProcessingError.ffmpegUnavailable
    }
    func cancel(operationID: UUID) async {}
}
