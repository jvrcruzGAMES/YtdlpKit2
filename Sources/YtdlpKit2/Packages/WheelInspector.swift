import Foundation

struct WheelInspection: Decodable, Sendable {
    let metadata: PackageMetadata
    let nativeFiles: [String]
    let tags: [String]
    let rootIsPurelib: Bool
}

struct SourceBuildSystem: Decodable, Sendable {
    let requires: [String]
    let backend: String
    let backendPath: [String]
    let nativeFiles: [String]
}

private struct BuildSystemEnvelope: Decodable {
    let ok: Bool
    let requires: [String]?
    let backend: String?
    let backendPath: [String]?
    let nativeFiles: [String]?
    let error: String?
}

private struct BuiltWheelEnvelope: Decodable {
    let ok: Bool
    let path: String?
    let error: String?
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

    static func decodeBuildSystem(_ json: String) throws -> SourceBuildSystem {
        let envelope = try decode(BuildSystemEnvelope.self, json)
        guard envelope.ok, let requires = envelope.requires, let backend = envelope.backend else {
            throw PackageManagerError.installationFailed(envelope.error ?? "build-system inspection failed")
        }
        return .init(requires: requires, backend: backend,
                     backendPath: envelope.backendPath ?? [], nativeFiles: envelope.nativeFiles ?? [])
    }

    static func decodeBuiltWheel(_ json: String) throws -> URL {
        let envelope = try decode(BuiltWheelEnvelope.self, json)
        guard envelope.ok, let path = envelope.path else {
            throw PackageManagerError.installationFailed(envelope.error ?? "wheel build failed")
        }
        return URL(fileURLWithPath: path)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw PackageManagerError.installationFailed("Python bridge returned invalid UTF-8")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
