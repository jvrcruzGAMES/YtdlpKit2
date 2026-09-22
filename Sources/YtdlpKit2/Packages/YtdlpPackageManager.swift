import Foundation

/// Installs and inventories Python distributions in a transactional site-packages root.
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
        try await migrateToSharedSitePackages(environment: environment, database: database)
        for package in await database.all() {
            guard FileManager.default.fileExists(atPath: package.installLocation.path) else {
                throw PackageManagerError.installationFailed(
                    "Managed package files are missing: \(package.normalizedName)"
                )
            }
        }
        let sitePackages = environment.packagesDirectory.appending(path: "installed")
        if FileManager.default.fileExists(atPath: sitePackages.path) {
            try await runtime.addPackagePath(sitePackages)
        }
        // Enforce exact core versions so a pin update also upgrades an existing
        // managed environment instead of retaining the old database entry.
        let pureCorePackages = [
            ("packaging", "26.3"),
            ("certifi", "2026.7.22"),
            ("charset-normalizer", "3.5.1"),
            ("idna", "3.20"),
            ("mutagen", "1.48.1"),
            ("urllib3", "2.8.0"),
            ("websockets", "17.1"),
            ("requests", "2.34.2"),
        ]
        for (name, version) in pureCorePackages
        where await database.package(named: name)?.version != version {
            _ = try await installPyPI(name: name, version: version,
                                      source: .pypi, role: .runtimeCore,
                                      resolveDependencies: false)
        }
        // OpenSSL has no system CA-file location inside an iOS application
        // sandbox. Install Mozilla's CA bundle explicitly and point every
        // Python HTTP backend at it before importing yt-dlp.
        _ = try await runtime.configureCertificateAuthorities()
        if await database.package(named: "yt-dlp")?.version != "2026.8.19" {
            _ = try await installPyPI(name: "yt-dlp", version: "2026.8.19",
                                      source: .pypi, role: .runtimeCore)
        }
        if await database.package(named: "yt-dlp-ejs")?.version != "0.8.0" {
            _ = try await installPyPI(name: "yt-dlp-ejs", version: "0.8.0",
                                      source: .pypi, role: .runtimeCore,
                                      resolveDependencies: false)
        }
        // This upstream plugin is pure Python. Its native implementation is the
        // signed WebKit framework supplied by Apple and linked by YtdlpKit2.
        if await database.package(named: "yt-dlp-apple-webkit-jsi")?.version != "0.1.1" {
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
            return try await installPEP508(value, role: .userInstalled)
        case let .git(url):
            return try await installGitHub(url: url, revision: nil, role: .userInstalled)
        case let .gitRevision(url, revision):
            return try await installGitHub(url: url, revision: revision, role: .userInstalled)
        }
    }

    /// Removes only files owned by the recorded distribution from shared site-packages.
    public func uninstall(_ package: String) async throws {
        try await prepare()
        let (environment, database, _) = try await context()
        guard let installed = await database.package(named: package) else { return }
        guard installed.role == .userInstalled else {
            throw PackageManagerError.protectedPackage(installed.name)
        }
        let managedRoot = environment.packagesDirectory.appending(path: "installed").standardizedFileURL.path
        let target = installed.installLocation.standardizedFileURL.path
        guard target == managedRoot else {
            throw PackageManagerError.installationFailed("Package database contains an unsafe install path")
        }
        try removeOwnedFiles(installed.files, from: installed.installLocation)
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
            return try await installGitHub(url: url, revision: revision, role: current.role)
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
        let installedRoot = environment.packagesDirectory.appending(path: "installed")
        try? await runtime.removePackagePath(installedRoot)
        try await database.reset()
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

    private func installPEP508(_ value: String, role: ManagedPackageRole) async throws -> InstalledPackage {
        let (_, _, runtime) = try await context()
        #if os(iOS)
        let sysPlatform = "ios"
        let platformSystem = "iOS"
        #else
        let sysPlatform = "darwin"
        let platformSystem = "Darwin"
        #endif
        let environment = """
        {"python_version":"3.14","python_full_version":"3.14.0","sys_platform":"\(sysPlatform)",\
        "platform_machine":"\(ProcessInfo.processInfo.machineArchitecture)",\
        "platform_system":"\(platformSystem)","implementation_name":"cpython"}
        """
        struct Parsed: Decodable { let name, specifier: String; let url: String?; let applies: Bool }
        let json = try await runtime.parseRequirement(value, environmentJSON: environment)
        guard let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode(Parsed.self, from: data) else {
            throw PackageManagerError.invalidRequirement(value)
        }
        guard parsed.applies else { throw PackageManagerError.invalidRequirement("marker does not apply: \(value)") }
        if let direct = parsed.url {
            let value = direct.hasPrefix("git+") ? String(direct.dropFirst(4)) : direct
            let split = value.range(of: ".git@", options: .backwards)
            let repository = split.map { String(value[..<$0.upperBound].dropLast()) } ?? value
            let revision = split.map { String(value[$0.upperBound...]) }
            guard let url = URL(string: repository), url.host?.lowercased() == "github.com" else {
                throw PackageManagerError.unsupportedGitSource(direct)
            }
            return try await installGitHub(url: url, revision: revision, role: role)
        }
        let resolver = PyPIResolver(policy: securityPolicy)
        let nativeRegistry = try NativePackageRegistry.bundled()
        if let native = nativeRegistry.descriptor(for: parsed.name) {
            let compatible = try await runtime.selectVersion(
                [native.version], specifier: parsed.specifier, allowPrereleases: false
            )
            guard !compatible.isEmpty else {
                throw PackageManagerError.nativeVersionMismatch(
                    "\(parsed.name) \(parsed.specifier) requires a version other than bundled \(native.version)"
                )
            }
            return try await installPyPI(name: parsed.name, version: native.version,
                                         source: .pypi, role: role)
        }
        let versions = try await resolver.versions(name: parsed.name)
        let selected = try await runtime.selectVersion(
            versions, specifier: parsed.specifier, allowPrereleases: securityPolicy.allowPrereleases
        )
        guard !selected.isEmpty else { throw PackageManagerError.versionNotFound(value) }
        return try await installPyPI(name: parsed.name, version: selected, source: .pypi,
                                     role: role)
    }

    private func installPyPI(name: String, version: String?, source: PackageSource,
                             role: ManagedPackageRole = .userInstalled,
                             resolveDependencies: Bool = true) async throws -> InstalledPackage {
        let nativeRegistry = try NativePackageRegistry.bundled()
        let bundledNative = nativeRegistry.descriptor(for: name)
        if let requested = version, let bundledNative, requested != bundledNative.version {
            throw PackageManagerError.nativeVersionMismatch(
                "\(name) \(requested); bundled version is \(bundledNative.version)"
            )
        }
        let resolvedVersion = version ?? bundledNative?.version
        let resolver = PyPIResolver(policy: securityPolicy)
        let artifact = try await resolver.resolve(
            name: name, exactVersion: resolvedVersion,
            allowBundledNativeWheel: bundledNative != nil
        )
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
        let inspection: WheelInspection
        switch artifact.format {
        case .wheel:
            inspection = try await runtime.inspectWheel(wheel)
        case .sourceArchive:
            inspection = try await runtime.inspectSourceArchive(
                wheel, fallbackVersion: artifact.fallbackVersion ?? artifact.version
            )
        }
        guard artifact.format == .sourceArchive ||
                (PackageName.normalize(inspection.metadata.name) == PackageName.normalize(artifact.name)
                 && inspection.metadata.version == artifact.version) else {
            throw PackageManagerError.installationFailed("Wheel metadata does not match resolved artifact")
        }
        let normalized = PackageName.normalize(inspection.metadata.name)
        let installedVersion = inspection.metadata.version
        if let allowed = securityPolicy.allowedPackageNames,
           !allowed.map(PackageName.normalize).contains(normalized) {
            throw PackageManagerError.packageNotFound(
                "\(inspection.metadata.name) is not allowed by policy"
            )
        }
        if normalized != "packaging", let requiresPython = inspection.metadata.requiresPython,
           try await runtime.selectVersion(
               ["3.14.0"], specifier: requiresPython, allowPrereleases: false
           ).isEmpty {
            throw PackageManagerError.incompatiblePython(
                "\(inspection.metadata.name) requires Python \(requiresPython)"
            )
        }
        let previouslyInstalled = await database.package(named: normalized)
        if role == .userInstalled, previouslyInstalled?.role == .runtimeCore {
            throw PackageManagerError.protectedPackage(inspection.metadata.name)
        }
        // Dependency resolution and runtime preparation are automatic. They
        // must never replace a distribution explicitly installed by the user.
        // An identical version is already sufficient; a different version is
        // reported as a conflict and the user's files/database entry remain
        // untouched. Explicit user installs and updates retain normal replace
        // semantics.
        if let previous = previouslyInstalled,
           previous.role == .userInstalled, role != .userInstalled {
            guard previous.version == installedVersion else {
                throw PackageManagerError.dependencyConflict(
                    "\(inspection.metadata.name) \(installedVersion) would replace user-installed \(previous.version)"
                )
            }
            return previous
        }

        let nativeRegistry = try NativePackageRegistry.bundled()
        let hasNative = !inspection.nativeFiles.isEmpty || !inspection.rootIsPurelib
        let nativeModules = nativeRegistry.descriptor(for: inspection.metadata.name)?.modules ?? []
        let nativeStatus: NativePackageStatus
        if hasNative {
            guard securityPolicy.binaryPolicy == .bundledOnly else {
                throw PackageManagerError.nativeBinaryUnavailable(artifact.name)
            }
            nativeStatus = nativeRegistry.status(name: inspection.metadata.name, version: installedVersion)
            guard nativeStatus == .bundledCompatible else {
                if nativeStatus == .bundledVersionMismatch {
                    throw PackageManagerError.nativeVersionMismatch("\(inspection.metadata.name) \(installedVersion)")
                }
                throw PackageManagerError.nativeBinaryUnavailable("\(inspection.metadata.name) \(installedVersion)")
            }
        } else { nativeStatus = .notRequired }

        if resolveDependencies && normalized != "packaging" {
            for requirement in inspection.metadata.requiresDist {
                do { _ = try await installPEP508(requirement, role: .ytdlpDependency) }
                catch PackageManagerError.invalidRequirement(let message) where message.hasPrefix("marker does not apply") { }
            }
        }

        let installedRoot = environment.packagesDirectory.appending(path: "installed")
        let transaction = environment.packagesDirectory.appending(path: ".staging")
            .appending(path: UUID().uuidString)
        let staged = transaction.appending(path: "package")
        let candidate = transaction.appending(path: "site-packages")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transaction) }
        var files: [String]
        switch artifact.format {
        case .wheel:
            files = try await runtime.extractWheel(wheel, to: staged, stripNative: hasNative)
        case .sourceArchive:
            guard !hasNative else {
                throw PackageManagerError.nativeBinaryUnavailable(inspection.metadata.name)
            }
            files = try await runtime.extractSourceArchive(
                wheel, to: staged,
                fallbackVersion: artifact.fallbackVersion ?? artifact.version
            )
        }
        if hasNative {
            files = try removeBundledNativeModules(
                nativeModules, files: files, from: staged
            )
        }
        let otherOwners = await database.all().filter { $0.normalizedName != normalized }
        let ownedByOthers = Set(otherOwners.flatMap(\.files))
        if let conflict = files.first(where: { ownedByOthers.contains($0) }) {
            throw PackageManagerError.dependencyConflict(
                "\(inspection.metadata.name) would overwrite \(conflict) owned by another package"
            )
        }
        if FileManager.default.fileExists(atPath: installedRoot.path) {
            try FileManager.default.copyItem(at: installedRoot, to: candidate)
        } else {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        }
        if let previous = previouslyInstalled {
            try removeOwnedFiles(previous.files, from: candidate)
        }
        for file in files {
            let source = staged.appending(path: file)
            let destination = candidate.appending(path: file)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw PackageManagerError.dependencyConflict(
                    "\(inspection.metadata.name) would overwrite unowned file \(file)"
                )
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let backup = transaction.appending(path: "previous-site-packages")
        if FileManager.default.fileExists(atPath: installedRoot.path) {
            try FileManager.default.moveItem(at: installedRoot, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: candidate, to: installedRoot)
            try await runtime.addPackagePath(installedRoot)
            let modulesToValidate = hasNative ? nativeModules : inspection.metadata.topLevelModules
            do { try await runtime.validateImports(modulesToValidate) }
            catch {
                throw PackageManagerError.installationFailed("Import validation failed: \(error)")
            }
            let installed = InstalledPackage(
                name: inspection.metadata.name, normalizedName: normalized,
                version: installedVersion, source: artifact.source, installDate: Date(),
                installLocation: installedRoot, files: files,
                dependencies: inspection.metadata.requiresDist, containsNativeCode: hasNative,
                nativeKind: hasNative ? .bundledNative : .purePython,
                nativeStatus: nativeStatus, metadata: inspection.metadata,
                artifactSHA256: artifact.sha256, role: role
            )
            try await database.record(installed)
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            return installed
        } catch {
            try? FileManager.default.removeItem(at: installedRoot)
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: installedRoot)
            }
            throw PackageManagerError.installationFailed(String(describing: error))
        }
    }

    private func migrateToSharedSitePackages(
        environment: PythonEnvironment, database: PackageDatabase
    ) async throws {
        let packages = await database.all()
        guard !packages.isEmpty else { return }
        let installedRoot = environment.packagesDirectory.appending(path: "installed")
            .standardizedFileURL
        guard packages.contains(where: {
            $0.installLocation.standardizedFileURL != installedRoot
        }) else { return }

        let transaction = environment.packagesDirectory
            .appending(path: ".migration-\(UUID().uuidString)")
        let candidate = transaction.appending(path: "site-packages")
        let backup = transaction.appending(path: "legacy")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transaction) }
        var migrated: [InstalledPackage] = []
        var claimed = Set<String>()
        for package in packages {
            let sourceRoot = package.installLocation
            guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
                throw PackageManagerError.installationFailed(
                    "Managed package files are missing: \(package.normalizedName)"
                )
            }
            let availableFiles = sourceRoot.standardizedFileURL == installedRoot
                ? package.files
                : try regularFiles(under: sourceRoot)
            let selected = package.nativeKind == .bundledNative
                ? availableFiles.filter { $0.contains(".dist-info/") }
                : availableFiles
            var copied: [String] = []
            for file in selected {
                let source = sourceRoot.appending(path: file)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                guard claimed.insert(file).inserted else {
                    throw PackageManagerError.dependencyConflict(
                        "Legacy packages both own \(file); migration cannot overwrite either"
                    )
                }
                let destination = candidate.appending(path: file)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(file)
            }
            migrated.append(copyOf(package, installLocation: installedRoot, files: copied))
        }
        if FileManager.default.fileExists(atPath: installedRoot.path) {
            try FileManager.default.moveItem(at: installedRoot, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: candidate, to: installedRoot)
            try await database.replaceAll(with: migrated)
        } catch {
            try? FileManager.default.removeItem(at: installedRoot)
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: installedRoot)
            }
            throw error
        }
    }

    private func regularFiles(under root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
        var files: [String] = []
        let rootPath = root.standardizedFileURL.path + "/"
        for case let item as URL in enumerator {
            guard try item.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            files.append(String(path.dropFirst(rootPath.count)))
        }
        return files.sorted()
    }

    private func copyOf(
        _ package: InstalledPackage, installLocation: URL, files: [String]
    ) -> InstalledPackage {
        InstalledPackage(
            name: package.name, normalizedName: package.normalizedName,
            version: package.version, source: package.source, installDate: package.installDate,
            installLocation: installLocation, files: files, dependencies: package.dependencies,
            containsNativeCode: package.containsNativeCode, nativeKind: package.nativeKind,
            nativeStatus: package.nativeStatus, metadata: package.metadata,
            artifactSHA256: package.artifactSHA256, role: package.role
        )
    }

    private func removeBundledNativeModules(
        _ modules: [String], files: [String], from root: URL
    ) throws -> [String] {
        let prefixes = modules.map { $0.replacingOccurrences(of: ".", with: "/") }
        let retained = files.filter { file in
            !prefixes.contains(where: { prefix in
                file == "\(prefix).py" || file == "\(prefix).pyi"
                    || file.hasPrefix(prefix + "/")
            })
        }
        let removed = Set(files).subtracting(retained)
        try removeOwnedFiles(Array(removed), from: root)
        return retained
    }

    private func removeOwnedFiles(_ files: [String], from root: URL) throws {
        let manager = FileManager.default
        let root = root.standardizedFileURL
        for file in files.sorted(by: { $0.count > $1.count }) {
            let target = root.appending(path: file).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw PackageManagerError.installationFailed("Unsafe package file path: \(file)")
            }
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            var parent = target.deletingLastPathComponent()
            while parent.path.hasPrefix(root.path + "/") {
                guard manager.fileExists(atPath: parent.path) else {
                    parent.deleteLastPathComponent()
                    continue
                }
                let contents = try manager.contentsOfDirectory(atPath: parent.path)
                guard contents.isEmpty else { break }
                try manager.removeItem(at: parent)
                parent.deleteLastPathComponent()
            }
        }
    }

    private func installGitHub(url: URL, revision: String?,
                               role: ManagedPackageRole) async throws -> InstalledPackage {
        guard securityPolicy.allowGitHub,
              url.host?.lowercased() == "github.com",
              securityPolicy.allowedGitHosts.contains("github.com") else {
            throw PackageManagerError.unsupportedGitSource(url.absoluteString)
        }
        let artifact = try await GitHubResolver(policy: securityPolicy).resolve(
            url: url, revision: revision
        )
        let key = "git:\(url.absoluteString)@\(artifact.fallbackVersion ?? artifact.version)"
        guard resolving.insert(key).inserted else {
            throw PackageManagerError.dependencyConflict("dependency cycle at \(key)")
        }
        defer { resolving.remove(key) }
        return try await installArtifact(
            artifact, role: role, resolveDependencies: true
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
