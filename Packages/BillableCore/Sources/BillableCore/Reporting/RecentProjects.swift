import Foundation
import SwiftData

/// Ranks the most-recently-worked projects for quick-resume surfaces
/// (Today's "Jump back in" row and the StartTimerSheet recents).
public enum RecentProjects {
    /// Distinct, non-archived projects ordered by their most recent entry
    /// (newest first), capped at `limit`. Sorts internally, so the caller's
    /// fetch order doesn't matter.
    ///
    /// Intentionally NOT `@MainActor`: the widget extension calls this from a
    /// non-isolated timeline context. It's a pure function over passed-in
    /// values, so it's safe to call synchronously from any actor.
    public static func rank(from entries: [TimeEntry], limit: Int) -> [Project] {
        guard limit > 0 else { return [] }
        let sorted = entries.sorted { $0.startedAt > $1.startedAt }
        var seen = Set<PersistentIdentifier>()
        var ordered: [Project] = []
        for entry in sorted {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted {
                ordered.append(project)
                if ordered.count == limit { break }
            }
        }
        return ordered
    }
}
