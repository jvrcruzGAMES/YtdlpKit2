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
        let previous = file
        file.packages[package.normalizedName] = package
        do { try persist() }
        catch {
            file = previous
            throw error
        }
    }

    func replaceAll(with packages: [InstalledPackage]) throws {
        let previous = file
        file.packages = Dictionary(uniqueKeysWithValues: packages.map {
            ($0.normalizedName, $0)
        })
        do { try persist() }
        catch {
            file = previous
            throw error
        }
    }

    func remove(named name: String) throws -> InstalledPackage? {
        let previous = file
        let removed = file.packages.removeValue(forKey: PackageName.normalize(name))
        do { try persist() }
        catch {
            file = previous
            throw error
        }
        return removed
    }

    func reset() throws {
        let previous = file
        file = PackageDatabaseFile()
        do { try persist() }
        catch {
            file = previous
            throw error
        }
    }

    private func persist() throws {
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
        } catch { throw PackageManagerError.installationFailed("Could not persist package database: \(error)") }
    }
}
