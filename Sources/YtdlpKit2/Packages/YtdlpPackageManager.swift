import Foundation

/// Installs and inventories pure-Python packages in transactional managed roots.
public actor YtdlpPackageManager {
    private let configuration: YtdlpConfiguration
    private let securityPolicy: PackageSecurityPolicy
    private var database: PackageDatabase?
    private var environment: PythonEnvironment?
    private var prepared = false
    private var preparationTask: Task<Void, Error>?
    private var resolving: Set<String> = []

    public init(configuration: YtdlpConfiguration = .init(),
                securityPolicy: PackageSecurityPolicy = .init()) {
        self.configuration = configuration
        self.securityPolicy = securityPolicy
    }

    func prepare() async throws {
        guard !prepared else { return }
        if let preparationTask { return try await preparationTask.value }
        let task = Task { try await self.performPreparation() }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    private func performPreparation() async throws {
        let (environment, database, runtime) = try await context()
        for package in await database.all() {
            guard FileManager.default.fileExists(atPath: package.installLocation.path) else {
                throw PackageManagerError.installationFailed(
                    "Managed package files are missing: \(package.normalizedName)"
                )
            }
            try await runtime.addPackagePath(package.installLocation)
        }
        // `packaging` supplies standards-compliant PEP 440, PEP 508, marker,
        // and tag semantics for all subsequent resolution.
        if await database.package(named: "packaging") == nil {
            _ = try await installPyPI(name: "packaging", version: "25.0",
                                      source: .pypi, role: .runtimeCore,
                                      resolveDependencies: false)
        }
        if await database.package(named: "yt-dlp") == nil {
            _ = try await installPyPI(name: "yt-dlp", version: "2026.8.19",
                                      source: .pypi, role: .runtimeCore)
        }
        if await database.package(named: "yt-dlp-ejs") == nil {
            _ = try await installPyPI(name: "yt-dlp-ejs", version: "0.8.0",
                                      source: .pypi, role: .runtimeCore,
                                      resolveDependencies: false)
        }
        // This upstream plugin is pure Python. Its native implementation is the
        // signed WebKit framework supplied by Apple and linked by YtdlpKit2.
        if await database.package(named: "yt-dlp-apple-webkit-jsi") == nil {
            _ = try await installPyPI(name: "yt-dlp-apple-webkit-jsi", version: "0.1.1",
                                      source: .pypi, role: .runtimeCore,
                                      resolveDependencies: false)
        }
        let loadedVersion = try await runtime.ytdlpVersion().string
        await runtime.setLoadedYtdlpVersion(loadedVersion)
        _ = environment
        prepared = true
    }

    /// Resolves, verifies, stages, validates, and atomically commits a package.
    public func install(_ requirement: PackageRequirement) async throws -> InstalledPackage {
        try await prepare()
        switch requirement {
        case let .pypi(name):
            return try await installPyPI(name: name, version: nil, source: .pypi)
        case let .pypiVersion(name, version):
            return try await installPyPI(name: name, version: version, source: .pypi)
        case let .pep508(value):
            return try await installPEP508(value)
        case let .git(url):
            return try await installGitHub(url: url, revision: nil)
        case let .gitRevision(url, revision):
            return try await installGitHub(url: url, revision: revision)
        }
    }

    /// Removes only the versioned root owned by the recorded distribution.
    public func uninstall(_ package: String) async throws {
        try await prepare()
        let (environment, database, runtime) = try await context()
        guard let installed = await database.package(named: package) else { return }
        guard installed.role == .userInstalled else {
            throw PackageManagerError.protectedPackage(installed.name)
        }
        let managedRoot = environment.packagesDirectory.appending(path: "installed").standardizedFileURL.path
        let target = installed.installLocation.standardizedFileURL.path
        guard target.hasPrefix(managedRoot + "/") else {
            throw PackageManagerError.installationFailed("Package database contains an unsafe install path")
        }
        try await runtime.removePackagePath(installed.installLocation)
        try FileManager.default.removeItem(at: installed.installLocation)
        _ = try await database.remove(named: installed.normalizedName)
    }

    /// Resolves the newest currently allowed PyPI release.
    public func update(_ package: String) async throws -> InstalledPackage {
        try await prepare()
        guard let current = try await self.package(named: package) else {
            throw PackageManagerError.packageNotFound(package)
        }
        switch current.source {
        case .pypi:
            return try await installPyPI(name: current.name, version: nil,
                                         source: .pypi, role: current.role)
        case let .git(url, revision):
            return try await installGitHub(url: url, revision: revision)
        case .bundled, .local:
            throw PackageManagerError.incompatiblePlatform("Local and bundled packages cannot be updated")
        }
    }

    /// Updates every non-local managed distribution.
    public func updateAll() async throws -> [InstalledPackage] {
        var result: [InstalledPackage] = []
        for package in try await installedPackages() {
            if package.role == .userInstalled { result.append(try await update(package.name)) }
        }
        return result
    }

    public func installedPackages() async throws -> [InstalledPackage] {
        try await prepare(); let (_, database, _) = try await context(); return await database.all()
    }

    public func package(named name: String) async throws -> InstalledPackage? {
        try await prepare(); let (_, database, _) = try await context()
        return await database.package(named: name)
    }

    public func diagnostics() async throws -> PackageManagerDiagnostics {
        try await prepare()
        let (_, database, _) = try await context()
        return PackageManagerDiagnostics(
            ready: prepared,
            nativeABI: try NativePackageRegistry.bundled().nativeABI,
            installedPackages: await database.all()
        )
    }

    /// Removes all manager-owned roots and rebuilds required core packages.
    public func resetPythonEnvironment() async throws {
        let (environment, database, runtime) = try await context()
        for package in await database.all() {
            try? await runtime.removePackagePath(package.installLocation)
            if FileManager.default.fileExists(atPath: package.installLocation.path) {
                try FileManager.default.removeItem(at: package.installLocation)
            }
        }
        try await database.reset()
        let installedRoot = environment.packagesDirectory.appending(path: "installed")
        if FileManager.default.fileExists(atPath: installedRoot.path) {
            try FileManager.default.removeItem(at: installedRoot)
        }
        prepared = false
        try await prepare()
    }

    private func context() async throws -> (PythonEnvironment, PackageDatabase, PythonRuntime) {
        let environment: PythonEnvironment
        if let existing = self.environment { environment = existing }
        else {
            environment = try PythonEnvironment(baseDirectory: configuration.applicationSupportDirectory)
            try environment.createDirectories(); self.environment = environment
        }
        let database: PackageDatabase
        if let existing = self.database { database = existing }
        else { database = try PackageDatabase(metadataDirectory: environment.metadataDirectory); self.database = database }
        let runtime = try await RuntimeStore.shared.acquire(configuration: configuration)
        try await runtime.prepare()
        return (environment, database, runtime)
    }

    private func installPEP508(_ value: String) async throws -> InstalledPackage {
        let (_, _, runtime) = try await context()
        let environment = """
        {"python_version":"3.14","python_full_version":"3.14.0","sys_platform":"darwin",\
        "platform_machine":"\(ProcessInfo.processInfo.machineArchitecture)",\
        "platform_system":"Darwin","implementation_name":"cpython"}
        """
        struct Parsed: Decodable { let name, specifier: String; let url: String?; let applies: Bool }
        let json = try await runtime.parseRequirement(value, environmentJSON: environment)
        guard let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode(Parsed.self, from: data) else {
            throw PackageManagerError.invalidRequirement(value)
        }
        guard parsed.applies else { throw PackageManagerError.invalidRequirement("marker does not apply: \(value)") }
        if let url = parsed.url { throw PackageManagerError.unsupportedGitSource(url) }
        let resolver = PyPIResolver(policy: securityPolicy)
        let versions = try await resolver.versions(name: parsed.name)
        let selected = try await runtime.selectVersion(
            versions, specifier: parsed.specifier, allowPrereleases: securityPolicy.allowPrereleases
        )
        guard !selected.isEmpty else { throw PackageManagerError.versionNotFound(value) }
        return try await installPyPI(name: parsed.name, version: selected, source: .pypi)
    }

    private func installPyPI(name: String, version: String?, source: PackageSource,
                             role: ManagedPackageRole = .userInstalled,
                             resolveDependencies: Bool = true) async throws -> InstalledPackage {
        let resolver = PyPIResolver(policy: securityPolicy)
        let artifact = try await resolver.resolve(name: name, exactVersion: version)
        let key = "\(PackageName.normalize(artifact.name))==\(artifact.version)"
        guard resolving.insert(key).inserted else {
            throw PackageManagerError.dependencyConflict("dependency cycle at \(key)")
        }
        defer { resolving.remove(key) }
        return try await installArtifact(artifact, role: role, resolveDependencies: resolveDependencies)
    }

    private func installArtifact(_ artifact: ResolvedPackageArtifact, role: ManagedPackageRole,
                                 resolveDependencies: Bool) async throws -> InstalledPackage {
        try Task.checkCancellation()
        let (environment, database, runtime) = try await context()
        let cache = PackageArtifactCache(directory: environment.cacheDirectory.appending(path: "packages"))
        let wheel = try await cache.download(artifact)
        let inspection = try await runtime.inspectWheel(wheel)
        guard PackageName.normalize(inspection.metadata.name) == PackageName.normalize(artifact.name),
              inspection.metadata.version == artifact.version else {
            throw PackageManagerError.installationFailed("Wheel metadata does not match resolved artifact")
        }

        let nativeRegistry = try NativePackageRegistry.bundled()
        let hasNative = !inspection.nativeFiles.isEmpty || !inspection.rootIsPurelib
        let nativeStatus: NativePackageStatus
        if hasNative {
            guard securityPolicy.binaryPolicy == .bundledOnly else {
                throw PackageManagerError.nativeBinaryUnavailable(artifact.name)
            }
            nativeStatus = nativeRegistry.status(name: artifact.name, version: artifact.version)
            guard nativeStatus == .bundledCompatible else {
                if nativeStatus == .bundledVersionMismatch {
                    throw PackageManagerError.nativeVersionMismatch("\(artifact.name) \(artifact.version)")
                }
                throw PackageManagerError.nativeBinaryUnavailable("\(artifact.name) \(artifact.version)")
            }
        } else { nativeStatus = .notRequired }

        if resolveDependencies && PackageName.normalize(artifact.name) != "packaging" {
            for requirement in inspection.metadata.requiresDist {
                do { _ = try await installPEP508(requirement) }
                catch PackageManagerError.invalidRequirement(let message) where message.hasPrefix("marker does not apply") { }
            }
        }

        let normalized = PackageName.normalize(artifact.name)
        let previouslyInstalled = await database.package(named: normalized)
        let installedRoot = environment.packagesDirectory.appending(path: "installed")
        let final = installedRoot.appending(path: normalized).appending(path: artifact.version)
        let transaction = environment.packagesDirectory.appending(path: ".staging")
            .appending(path: UUID().uuidString)
        let staged = transaction.appending(path: "root")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transaction) }
        let files = try await runtime.extractWheel(wheel, to: staged, stripNative: hasNative)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = transaction.appending(path: "previous")
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: final, to: backup) }
        do {
            try FileManager.default.moveItem(at: staged, to: final)
            try await runtime.addPackagePath(final)
            do { try await runtime.validateImports(inspection.metadata.topLevelModules) }
            catch {
                try? await runtime.removePackagePath(final)
                throw PackageManagerError.installationFailed("Import validation failed: \(error)")
            }
            let installed = InstalledPackage(
                name: inspection.metadata.name, normalizedName: normalized,
                version: artifact.version, source: artifact.source, installDate: Date(),
                installLocation: final, files: files,
                dependencies: inspection.metadata.requiresDist, containsNativeCode: hasNative,
                nativeKind: hasNative ? .bundledNative : .purePython,
                nativeStatus: nativeStatus, metadata: inspection.metadata,
                artifactSHA256: artifact.sha256, role: role
            )
            try await database.record(installed)
            if let previous = previouslyInstalled,
               previous.installLocation.standardizedFileURL != final.standardizedFileURL {
                try? await runtime.removePackagePath(previous.installLocation)
                try? FileManager.default.removeItem(at: previous.installLocation)
            }
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            return installed
        } catch {
            try? FileManager.default.removeItem(at: final)
            if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: final) }
            throw PackageManagerError.installationFailed(String(describing: error))
        }
    }

    private func installGitHub(url: URL, revision: String?) async throws -> InstalledPackage {
        guard securityPolicy.allowGitHub,
              url.host?.lowercased() == "github.com",
              securityPolicy.allowedGitHosts.contains("github.com") else {
            throw PackageManagerError.unsupportedGitSource(url.absoluteString)
        }
        throw PackageManagerError.unsupportedBuildBackend(
            "GitHub source archives require a pure-Python PEP 517 backend; runtime source builds are not enabled yet"
        )
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
