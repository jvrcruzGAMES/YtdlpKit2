import Foundation

private struct PackageDatabaseFile: Codable {
    var schemaVersion = 1
    var packages: [String: InstalledPackage] = [:]
}

actor PackageDatabase {
    private let url: URL
    private var file: PackageDatabaseFile

    init(metadataDirectory: URL) throws {
        url = metadataDirectory.appending(path: "packages-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { file = try JSONDecoder().decode(PackageDatabaseFile.self, from: Data(contentsOf: url)) }
            catch { throw PackageManagerError.installationFailed("Invalid package database: \(error)") }
        } else { file = PackageDatabaseFile() }
    }

    func all() -> [InstalledPackage] {
        file.packages.values.sorted { $0.normalizedName < $1.normalizedName }
    }

    func package(named name: String) -> InstalledPackage? {
        file.packages[PackageName.normalize(name)]
    }

    func record(_ package: InstalledPackage) throws {
        file.packages[package.normalizedName] = package
        try persist()
    }

    func remove(named name: String) throws -> InstalledPackage? {
        let removed = file.packages.removeValue(forKey: PackageName.normalize(name))
        try persist()
        return removed
    }

    func reset() throws {
        file = PackageDatabaseFile(); try persist()
    }

    private func persist() throws {
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
        } catch { throw PackageManagerError.installationFailed("Could not persist package database: \(error)") }
    }
}
