import Foundation

final class SecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private let active: Bool

    init(_ url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    deinit { if active { url.stopAccessingSecurityScopedResource() } }
}
