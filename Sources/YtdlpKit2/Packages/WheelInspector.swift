import Foundation

struct WheelInspection: Decodable, Sendable {
    let metadata: PackageMetadata
    let nativeFiles: [String]
    let tags: [String]
    let rootIsPurelib: Bool
}

private struct InspectionEnvelope: Decodable {
    let ok: Bool
    let metadata: PackageMetadata?
    let nativeFiles: [String]?
    let tags: [String]?
    let rootIsPurelib: Bool?
    let error: String?
}

private struct ExtractionEnvelope: Decodable {
    let ok: Bool
    let files: [String]?
    let error: String?
}

enum WheelInspector {
    static func decodeInspection(_ json: String) throws -> WheelInspection {
        let envelope = try decode(InspectionEnvelope.self, json)
        guard envelope.ok, let metadata = envelope.metadata else {
            throw PackageManagerError.installationFailed(envelope.error ?? "wheel inspection failed")
        }
        return .init(metadata: metadata, nativeFiles: envelope.nativeFiles ?? [],
                     tags: envelope.tags ?? [], rootIsPurelib: envelope.rootIsPurelib ?? false)
    }

    static func decodeExtraction(_ json: String) throws -> [String] {
        let envelope = try decode(ExtractionEnvelope.self, json)
        guard envelope.ok else {
            throw PackageManagerError.installationFailed(envelope.error ?? "wheel extraction failed")
        }
        return envelope.files ?? []
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw PackageManagerError.installationFailed("Python bridge returned invalid UTF-8")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
