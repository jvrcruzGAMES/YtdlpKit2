import Foundation

actor CancellationRegistry {
    private var cancelled: Set<UUID> = []
    func register() -> UUID { UUID() }
    func cancel(_ id: UUID) { cancelled.insert(id) }
    func isCancelled(_ id: UUID) -> Bool { cancelled.contains(id) }
    func remove(_ id: UUID) { cancelled.remove(id) }
}
