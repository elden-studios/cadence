import Foundation
import AppIntents
import SwiftData

// MARK: - Start

public struct StartTimerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start timer"
    public static let description = IntentDescription(
        "Start tracking time on a project.",
        categoryName: "Timer"
    )
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Project")
    public var project: ProjectEntity

    public init() {}
    public init(project: ProjectEntity) { self.project = project }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = IntentContainer.shared.container else {
            return .result(dialog: "Billable isn't ready yet — open the app once and try again.")
        }
        let context = ModelContext(container)
        guard let project = try resolveProject(in: context) else {
            return .result(dialog: "I couldn't find that project. It may have been archived.")
        }
        do {
            _ = try TimerService.start(project: project, in: context)
            return .result(dialog: "Started timer for \(project.name).")
        } catch TimerService.TimerError.projectIsArchived {
            return .result(dialog: "That project is archived.")
        } catch {
            return .result(dialog: "Couldn't start the timer.")
        }
    }

    @MainActor
    private func resolveProject(in context: ModelContext) throws -> Project? {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        let candidates = try context.fetch(descriptor)
        return candidates.first { $0.persistentModelID.storeIdentifier == project.id }
    }
}

// MARK: - Stop

public struct StopTimerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop timer"
    public static let description = IntentDescription(
        "Stop the currently running timer.",
        categoryName: "Timer"
    )
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = IntentContainer.shared.container else {
            return .result(dialog: "Billable isn't ready yet.")
        }
        let context = ModelContext(container)
        do {
            let stopped = try TimerService.stop(in: context)
            let label = stopped.project?.name ?? "Timer"
            return .result(dialog: "Stopped \(label).")
        } catch TimerService.TimerError.noRunningTimer {
            return .result(dialog: "No timer is currently running.")
        } catch {
            return .result(dialog: "Couldn't stop the timer.")
        }
    }
}

// MARK: - Switch

public struct SwitchTimerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Switch timer to project"
    public static let description = IntentDescription(
        "Stop the current timer and start a new one on another project, with no gap.",
        categoryName: "Timer"
    )
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Project")
    public var project: ProjectEntity

    public init() {}
    public init(project: ProjectEntity) { self.project = project }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = IntentContainer.shared.container else {
            return .result(dialog: "Billable isn't ready yet.")
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        let candidates = try context.fetch(descriptor)
        guard let target = candidates.first(where: { $0.persistentModelID.storeIdentifier == project.id }) else {
            return .result(dialog: "I couldn't find that project.")
        }
        do {
            _ = try TimerService.switchTo(project: target, in: context)
            return .result(dialog: "Switched timer to \(target.name).")
        } catch TimerService.TimerError.alreadyTrackingSameProject {
            return .result(dialog: "Already tracking that project.")
        } catch {
            return .result(dialog: "Couldn't switch the timer.")
        }
    }
}

// MARK: - Log completed entry

public struct LogCompletedTimeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Log time entry"
    public static let description = IntentDescription(
        "Log a completed block of time on a project — useful for after-the-fact entries.",
        categoryName: "Timer"
    )
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Project")
    public var project: ProjectEntity

    @Parameter(title: "Start")
    public var start: Date

    @Parameter(title: "End")
    public var end: Date

    @Parameter(title: "Notes", default: "")
    public var notes: String

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = IntentContainer.shared.container else {
            return .result(dialog: "Billable isn't ready yet.")
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        let candidates = try context.fetch(descriptor)
        guard let target = candidates.first(where: { $0.persistentModelID.storeIdentifier == project.id }) else {
            return .result(dialog: "Project not found.")
        }
        do {
            _ = try TimerService.logCompletedEntry(
                project: target,
                start: start,
                end: end,
                notes: notes.isEmpty ? nil : notes,
                in: context
            )
            return .result(dialog: "Logged \(target.name) entry.")
        } catch {
            return .result(dialog: "Couldn't log the entry.")
        }
    }
}

// MARK: - Shortcuts provider

/// Exposes the intents to the Shortcuts app and Siri as suggested phrases.
public struct BillableShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: [
                "Start \(.applicationName) timer",
                "Start \(.applicationName) for \(\.$project)",
                "Start tracking \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Start timer",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: [
                "Stop \(.applicationName) timer",
                "Stop my \(.applicationName)",
            ],
            shortTitle: "Stop timer",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SwitchTimerIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$project)",
            ],
            shortTitle: "Switch timer",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
