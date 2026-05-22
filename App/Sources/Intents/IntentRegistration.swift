import AppIntents
import BillableCore

/// Forces the main app target to link AppIntents.framework so the build system
/// runs metadata extraction on `BillableShortcuts` and our intent types.
/// Without an explicit import in this target, the App Intents discovery step
/// is skipped and Siri/Shortcuts don't see the phrases.
private struct IntentLinkage {
    @MainActor static let value: Any = BillableShortcuts.appShortcuts
}
