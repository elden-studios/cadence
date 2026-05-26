import Foundation
import OSLog
import SwiftData

extension ModelContext {
    /// Saves the context, swallowing the error but recording it via OSLog with full call-site info.
    ///
    /// This is a drop-in replacement for `try? modelContext.save()` that preserves the
    /// silent-failure ergonomics at SwiftUI call sites while making failures visible in Console.app
    /// and during debugging.
    ///
    /// - Parameters:
    ///   - context: Optional short description of what was being saved (e.g. "after adding client").
    ///   - file: Source file where the save was attempted. Captured automatically.
    ///   - line: Line number where the save was attempted. Captured automatically.
    @MainActor
    public func saveOrLog(
        _ context: String = "",
        file: String = #fileID,
        line: Int = #line
    ) {
        do {
            try self.save()
        } catch {
            let logger = Logger(
                subsystem: "com.eldenstudios.billable",
                category: "persistence"
            )
            logger.error(
                "ModelContext save failed at \(file, privacy: .public):\(line, privacy: .public) (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
