import Foundation
import PythonKit

/// All PythonKit values are deliberately scoped to synchronous calls made by
/// `PythonRuntime`; none escape the runtime actor.
struct PythonBridge {
    func configureSearchPath(_ paths: [String]) throws {
        do {
            let sys = try Python.attemptImport("sys")
            for path in paths.reversed() {
                if !Bool(sys.path.__contains__(path))! {
                    _ = try sys.path.insert.throwing.dynamicallyCall(withArguments: [0, path])
                }
            }
        } catch {
            throw YtdlpKitError.pythonExecutionFailed(String(describing: error))
        }
    }

    func runtimeInformation() throws -> RuntimeInformation {
        do {
            let module = try Python.attemptImport("bootstrap")
            let value = try module.runtime_info.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )
            return RuntimeInformation(
                pythonVersion: String(value["python_version"]) ?? "",
                implementation: String(value["implementation"]) ?? "",
                platform: String(value["sys_platform"]) ?? "",
                architecture: String(value["machine"]) ?? "",
                searchPaths: Array<String>(value["sys_path"]) ?? []
            )
        } catch {
            throw YtdlpKitError.pythonExecutionFailed(String(describing: error))
        }
    }

    func validate() throws {
        do {
            let bootstrap = try Python.attemptImport("bootstrap")
            guard Bool(try bootstrap.validate_environment.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) == true else {
                throw YtdlpKitError.invalidEnvironment("bootstrap validation returned false")
            }
            for name in ["json", "pathlib", "urllib.parse", "hashlib", "asyncio", "bridge_test"] {
                _ = try Python.attemptImport(name)
            }
            // Native modules are registered before Py_Initialize and imported
            // here so a missing architecture slice fails during preparation.
            _ = try Python.attemptImport("brotli")
            guard Bool(try bootstrap.validate_brotli.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) == true else {
                throw YtdlpKitError.invalidEnvironment("Brotli native round trip failed")
            }
            guard Bool(try bootstrap.validate_native_packages.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) == true else {
                throw YtdlpKitError.invalidEnvironment("Native package self-test failed")
            }
            let test = try Python.attemptImport("bridge_test")
            let result = try test.double_value.throwing.dynamicallyCall(withArguments: [21])
            guard Int(result) == 42 else {
                throw YtdlpKitError.pythonExecutionFailed("Swift → Python bridge returned \(result)")
            }
        } catch let error as YtdlpKitError {
            throw error
        } catch {
            throw YtdlpKitError.pythonImportFailed(String(describing: error))
        }
    }

    func nativeBridgeVersion() throws -> String {
        do {
            let native = try Python.attemptImport("_ytdlpkit_native")
            return String(try native.bridge_version.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) ?? ""
        } catch {
            throw YtdlpKitError.pythonImportFailed("_ytdlpkit_native: \(error)")
        }
    }

    func bootstrapYtdlp(wheel: URL, sitePackages: URL) throws -> String {
        do {
            let module = try Python.attemptImport("ytdlp_bridge")
            let value = try module.ensure_ytdlp.throwing.dynamicallyCall(
                withArguments: [wheel.path, sitePackages.path]
            )
            return String(value) ?? ""
        } catch {
            throw YtdlpKitError.pythonImportFailed("yt-dlp bootstrap: \(error)")
        }
    }

    func ytdlpVersion() throws -> String {
        do {
            let module = try Python.attemptImport("ytdlp_bridge")
            return String(try module.version.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) ?? ""
        } catch {
            throw YtdlpError.python(String(describing: error))
        }
    }

    func ffmpegBridgeStatus() throws -> String {
        do {
            let module = try Python.attemptImport("ytdlp_bridge")
            return String(try module.ffmpeg_bridge_status.throwing.dynamicallyCall(
                withArguments: [] as [any PythonConvertible]
            )) ?? ""
        } catch {
            throw YtdlpKitError.pythonImportFailed("FFmpeg compatibility bridge: \(error)")
        }
    }

    func ffmpegBridgeMerge(video: String, audio: String, output: String,
                           operationID: String) throws -> String {
        do {
            let module = try Python.attemptImport("ytdlp_bridge")
            return String(try module.ffmpeg_bridge_merge.throwing.dynamicallyCall(
                withArguments: [video, audio, output, operationID]
            )) ?? ""
        } catch {
            throw YtdlpKitError.pythonImportFailed("yt-dlp FFmpeg merge: \(error)")
        }
    }

    func extract(url: String, optionsJSON: String) throws -> String {
        try callYtdlp(function: "extract", arguments: [url, optionsJSON])
    }

    func download(url: String, optionsJSON: String, operationID: String,
                  outputDirectory: String) throws -> String {
        try callYtdlp(
            function: "download",
            arguments: [url, optionsJSON, operationID, outputDirectory]
        )
    }

    func testYtdlpCallbacks(operationID: String) throws -> String {
        try callYtdlp(function: "bridge_callback_test", arguments: [operationID])
    }

    func inspectWheel(_ url: URL) throws -> String {
        try call(module: "package_bridge", function: "inspect_wheel", arguments: [url.path])
    }

    func extractWheel(_ wheel: URL, to destination: URL, stripNative: Bool) throws -> String {
        try call(module: "package_bridge", function: "extract_wheel",
                 arguments: [wheel.path, destination.path, stripNative])
    }

    func addPackagePath(_ url: URL) throws {
        _ = try call(module: "package_bridge", function: "add_search_path", arguments: [url.path])
    }

    func removePackagePath(_ url: URL) throws {
        _ = try call(module: "package_bridge", function: "remove_search_path", arguments: [url.path])
    }

    func validateImports(_ modules: [String]) throws {
        _ = try call(module: "package_bridge", function: "validate_imports", arguments: [modules])
    }

    func parseRequirement(_ requirement: String, environmentJSON: String) throws -> String {
        try call(module: "package_bridge", function: "parse_requirement",
                 arguments: [requirement, environmentJSON])
    }

    func selectVersion(_ versions: [String], specifier: String,
                       allowPrereleases: Bool) throws -> String {
        try call(module: "package_bridge", function: "select_version",
                 arguments: [versions, specifier, allowPrereleases])
    }

    func pluginInventory(refresh: Bool) throws -> String {
        try call(module: "ytdlp_plugin_bridge",
                 function: refresh ? "refresh_plugins" : "list_plugins", arguments: [])
    }

    func matchingExtractors(url: String) throws -> String {
        try call(module: "ytdlp_plugin_bridge", function: "matching_extractors", arguments: [url])
    }

    private func callYtdlp(function: String, arguments: [any PythonConvertible]) throws -> String {
        try call(module: "ytdlp_bridge", function: function, arguments: arguments)
    }

    private func call(module moduleName: String, function: String,
                      arguments: [any PythonConvertible]) throws -> String {
        do {
            let module = try Python.attemptImport(moduleName)
            let callable = module[dynamicMember: function]
            return String(try callable.throwing.dynamicallyCall(withArguments: arguments)) ?? ""
        } catch {
            throw YtdlpError.python(String(describing: error))
        }
    }
}

struct RuntimeInformation {
    let pythonVersion: String
    let implementation: String
    let platform: String
    let architecture: String
    let searchPaths: [String]
}
