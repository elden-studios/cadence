import Foundation
import SwiftData

/// Holds the shared `ModelContainer` that App Intents (and other framework
/// callers) need to reach. The main app sets this on launch before any intent
/// can fire — Siri/Shortcuts invocations bring the app to the foreground first,
/// so the container is wired up by the time `perform()` runs.
///
/// Wrapped in a class so reads are reference-safe across the dispatch boundary
/// that App Intents introduce.
public final class IntentContainer: @unchecked Sendable {
    public static let shared = IntentContainer()

    private var _container: ModelContainer?
    private let lock = NSLock()

    private init() {}

    public var container: ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return _container
    }

    public func setContainer(_ container: ModelContainer) {
        lock.lock(); defer { lock.unlock() }
        _container = container
    }
}
