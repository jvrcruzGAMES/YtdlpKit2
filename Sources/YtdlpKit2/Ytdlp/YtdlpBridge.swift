import Foundation

private struct BridgeErrorPayload: Decodable {
    let kind: String
    let message: String
    let traceback: String?
}

private struct ExtractionEnvelope: Decodable {
    let ok: Bool
    let value: YtdlpMediaInfo?
    let error: BridgeErrorPayload?
}

private struct DownloadPayload: Decodable {
    let mediaInfo: YtdlpMediaInfo
    let files: [String]
    let primaryFile: String?
}

private struct DownloadEnvelope: Decodable {
    let ok: Bool
    let value: DownloadPayload?
    let error: BridgeErrorPayload?
}

enum YtdlpBridge {
    static func decodeExtraction(_ json: String) throws -> YtdlpMediaInfo {
        let envelope: ExtractionEnvelope = try decode(json)
        guard envelope.ok, let value = envelope.value else { throw translated(envelope.error) }
        return value
    }

    static func decodeDownload(_ json: String, outputDirectory: URL) throws -> YtdlpDownloadResult {
        let envelope: DownloadEnvelope = try decode(json)
        guard envelope.ok, let value = envelope.value else { throw translated(envelope.error) }
        let files = value.files.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let primary = value.primaryFile.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return .init(mediaInfo: value.mediaInfo, files: files,
                     primaryFile: primary, outputDirectory: outputDirectory)
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw YtdlpError.python("Bridge returned invalid UTF-8")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw YtdlpError.python("Invalid bridge response: \(error)") }
    }

    private static func translated(_ payload: BridgeErrorPayload?) -> YtdlpError {
        guard let payload else { return .unknown("yt-dlp returned no result") }
        let detail = payload.traceback.map { "\(payload.message)\n\($0)" } ?? payload.message
        switch payload.kind {
        case "cancelled": return .cancelled
        case "extraction": return .extractionFailed(detail)
        case "download": return .downloadFailed(detail)
        case "unsupported": return .unsupportedURL(detail)
        case "login_required": return .loginRequired(detail)
        case "authentication": return .authenticationFailed(detail)
        case "geo_restricted": return .geoRestricted(detail)
        case "unavailable": return .unavailable(detail)
        case "network": return .network(detail)
        default: return .python(detail)
        }
    }

    static func optionsJSON(_ options: YtdlpOptions) throws -> String {
        if let cookies = options.cookiesFile,
           !FileManager.default.isReadableFile(atPath: cookies.path) {
            throw YtdlpKitError.invalidEnvironment("Cookies file is not readable: \(cookies.path)")
        }
        var value = options.additionalOptions
        func set(_ key: String, _ item: JSONValue?) { if let item { value[key] = item } }
        set("cookiefile", options.cookiesFile.map { .string($0.path) })
        set("username", options.username.map(JSONValue.string))
        set("password", options.password.map(JSONValue.string))
        set("videopassword", options.videoPassword.map(JSONValue.string))
        set("proxy", options.proxy.map(JSONValue.string))
        set("geo_bypass", options.geoBypass.map(JSONValue.bool))
        set("socket_timeout", options.socketTimeout.map(JSONValue.number))
        set("playliststart", options.playlistStart.map { .number(Double($0)) })
        set("playlistend", options.playlistEnd.map { .number(Double($0)) })
        set("playlist_items", options.playlistItems.map(JSONValue.string))
        value["ignoreerrors"] = .bool(options.ignoreErrors)
        value["nocheckcertificate"] = .bool(options.noCheckCertificates)
        value["extract_flat"] = .bool(options.extractFlat)
        value["allow_unplayable_formats"] = .bool(options.allowUnplayableFormats)
        var headers = options.httpHeaders
        if let userAgent = options.userAgent { headers["User-Agent"] = userAgent }
        if let referer = options.referer { headers["Referer"] = referer }
        if !headers.isEmpty { value["http_headers"] = .object(headers.mapValues(JSONValue.string)) }
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func downloadOptionsJSON(_ request: YtdlpRequest) throws -> String {
        var object = try decodedOptions(request.options)
        object["format"] = .string(request.format.expression)
        let template = request.outputTemplate ?? "%(title)s [%(id)s].%(ext)s"
        object["outtmpl"] = .string(request.outputDirectory.appendingPathComponent(template).path)
        object["overwrites"] = .bool(request.overwriteExisting)
        object["continuedl"] = .bool(request.continuePartialDownloads)
        object["writethumbnail"] = .bool(request.writeThumbnail)
        object["writeinfojson"] = .bool(request.writeMetadataJSON)
        object["writesubtitles"] = .bool(request.writeSubtitles)
        object["writeautomaticsub"] = .bool(request.writeAutomaticSubtitles)
        if !request.subtitleLanguages.isEmpty {
            object["subtitleslangs"] = .array(request.subtitleLanguages.map(JSONValue.string))
        }
        var postprocessors: [JSONValue] = []
        if let extraction = request.audioExtraction {
            var processor: [String: JSONValue] = [
                "key": .string("FFmpegExtractAudio"),
                "preferredcodec": .string(extraction.format.rawValue),
            ]
            if let quality = extraction.quality { processor["preferredquality"] = .string(quality) }
            postprocessors.append(.object(processor))
        }
        if let remux = request.remux {
            postprocessors.append(.object([
                "key": .string("FFmpegVideoRemuxer"), "preferedformat": .string(remux.rawValue),
            ]))
        }
        if request.embedMetadata {
            postprocessors.append(.object(["key": .string("FFmpegMetadata")]))
        }
        if request.embedThumbnail {
            object["writethumbnail"] = .bool(true)
            postprocessors.append(.object(["key": .string("EmbedThumbnail")]))
        }
        if request.embedSubtitles {
            object["writesubtitles"] = .bool(true)
            postprocessors.append(.object(["key": .string("FFmpegEmbedSubtitle")]))
        }
        if !postprocessors.isEmpty { object["postprocessors"] = .array(postprocessors) }
        return String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }

    private static func decodedOptions(_ options: YtdlpOptions) throws -> [String: JSONValue] {
        let data = Data(try optionsJSON(options).utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
