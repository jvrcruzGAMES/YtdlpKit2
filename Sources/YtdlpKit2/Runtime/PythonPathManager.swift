import Foundation

struct PythonPathManager: Sendable {
    private(set) var paths: [URL] = []

    mutating func add(_ url: URL) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !paths.contains(where: { $0.path == normalized.path }) else { return }
        paths.append(normalized)
    }

    var strings: [String] { paths.map(\.path) }
}
