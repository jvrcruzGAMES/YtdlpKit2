import Foundation
import PythonKit
import YtdlpKit2Native
#if canImport(Darwin)
import Darwin
#endif

struct RuntimeBootstrap {
    let environment: PythonEnvironment
    let configuration: YtdlpConfiguration

    func start() throws -> (RuntimeInformation, String, [String]) {
        func trace(_ message: String) {
            guard configuration.verboseLogging else { return }
            YtdlpLog.runtime.debug("\(message, privacy: .public)")
        }
        try environment.createDirectories()
        // Install the synchronous C ABI endpoint before Python or yt-dlp can
        // perform and cache FFmpeg availability detection.
        MediaBridgeRegistration.install()
        trace("directories ready")
        let manifest = try RuntimeManifest.bundled()
        let libraryURL = try bundledPythonLibrary()
        let pythonHome = try bundledPythonHome()
        trace("resources resolved")

        unsetenv("PYTHONPATH")
        setenv("PYTHONHOME", pythonHome.path, 1)
        setenv("YTDLPKIT_FRAMEWORK_PATHS", frameworkSearchPaths().joined(separator: ":"), 1)
        preloadFrameworkLibraries(for: libraryURL)
        PythonLibrary.useLibrary(at: libraryURL.path)
        do {
            try PythonLibrary.loadLibrary()
            trace("CPython image loaded")
        } catch {
            throw YtdlpKitError.pythonInitializationFailed(
                "Could not load signed CPython at \(libraryURL.path): \(error)"
            )
        }

        environment.rootDirectory.path.withCString { YtdlpKit2_SetRuntimeRoot($0) }
        guard YtdlpKit2_RegisterNativePythonModules() == 0 else {
            throw YtdlpKitError.pythonInitializationFailed(
                "Could not register statically bundled Python modules before initialization"
            )
        }
        trace("native modules registered")

        var pathManager = PythonPathManager()
        guard let pythonModules = Bundle.module.url(
            forResource: "Python", withExtension: nil, subdirectory: nil
        ) else {
            throw YtdlpKitError.invalidEnvironment("Bundled Python bridge modules are missing")
        }
        pathManager.add(pythonModules)
        pathManager.add(environment.sitePackagesDirectory)
        pathManager.add(environment.pluginsDirectory)
        pathManager.add(environment.packagesDirectory)
        configuration.additionalPythonPaths.forEach { pathManager.add($0) }
        configuration.additionalPluginDirectories.forEach { pathManager.add($0) }

        let bridge = PythonBridge()
        trace("initializing interpreter")
        defer { YtdlpKit2_ReleaseInitialGIL() }
        try bridge.configureSearchPath(pathManager.strings)
        trace("search path configured")
        try bridge.validate()
        trace("Python bridge validated")
        let information = try bridge.runtimeInformation()
        trace("runtime information read")
        try manifest.validate(pythonVersion: information.pythonVersion)
        let nativeVersion = try bridge.nativeBridgeVersion()
        trace("native bridge validated")
        return (information, nativeVersion, pathManager.strings)
    }

    private func bundledPythonLibrary() throws -> URL {
        let names = ["Python", "libPython3.14.dylib", "libpython3.14.dylib"]
        var directories: [URL] = []
        directories.append(contentsOf: Bundle.allFrameworks
            .filter { $0.bundleURL.lastPathComponent == "Python.framework" }
            .map(\.bundleURL))
        if let frameworks = Bundle.main.privateFrameworksURL {
            directories.append(frameworks.appending(path: "Python.framework"))
            directories.append(frameworks)
        }
        var ancestor = Bundle.module.bundleURL
        for _ in 0..<6 {
            ancestor.deleteLastPathComponent()
            directories.append(ancestor.appending(path: "Python.framework"))
        }
        directories.append(Bundle.module.bundleURL.appending(path: "Runtime"))

        for directory in directories {
            for name in names {
                let candidate = directory.appending(path: name)
                if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw YtdlpKitError.runtimeNotFound
    }

    private func bundledPythonHome() throws -> URL {
        let candidates = [
            Bundle.module.resourceURL?.appending(path: "Runtime/python", directoryHint: .isDirectory),
            Bundle.main.resourceURL?.appending(path: "python", directoryHint: .isDirectory),
        ].compactMap { $0 }
        for candidate in candidates {
            let standardLibrary = candidate.appending(path: "lib/python3.14", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardLibrary.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        throw YtdlpKitError.invalidEnvironment(
            "Bundled Python 3.14 standard library is missing from the resource bundle"
        )
    }

    private func preloadFrameworkLibraries(for python: URL) {
        #if canImport(Darwin)
        let framework = python.deletingLastPathComponent()
        let libraryDirectory = framework.appending(path: "Versions/3.14/lib")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: libraryDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for library in contents.filter({ $0.pathExtension == "dylib" }).sorted(by: { $0.path < $1.path }) {
            _ = dlopen(library.path, RTLD_NOW | RTLD_GLOBAL)
        }
        #endif
    }

    private func frameworkSearchPaths() -> [String] {
        var paths = Bundle.allFrameworks.map { $0.bundleURL.deletingLastPathComponent().path }
        if let frameworks = Bundle.main.privateFrameworksURL { paths.append(frameworks.path) }
        var ancestor = Bundle.module.bundleURL
        for _ in 0..<10 {
            ancestor.deleteLastPathComponent()
            paths.append(ancestor.path)
            paths.append(ancestor.appending(path: "Frameworks").path)
            paths.append(ancestor.appending(path: "Native/PythonExtensions").path)
            paths.append(ancestor.appending(path: "Native/PythonStdlibExtensions").path)
            paths.append(ancestor.appending(path: "Native/CPython").path)
        }
        return Array(Set(paths.filter { FileManager.default.fileExists(atPath: $0) })).sorted()
    }
}
