import SwiftUI
import SwiftData
import BillableCore

/// Today-screen banner shown when there are pending recurrence materializations
/// (i.e., `RecurrenceTemplate` rows whose `nextFireDate` is in the past and
/// have not yet been materialized into a Draft invoice).
///
/// Tapping the banner pushes a list view where each row materializes a single
/// template on tap. We deliberately avoid auto-materializing all pending rows
/// at once to prevent a "stampede" of drafts when a user returns to the app
/// after a long absence.
struct CatchUpBanner: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurrenceTemplate.nextFireDate) private var allTemplates: [RecurrenceTemplate]

    var body: some View {
        let pending = pendingTemplates()
        if !pending.isEmpty {
            NavigationLink(value: PendingMaterializationsLink()) {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pending.count) recurring invoice\(pending.count == 1 ? "" : "s") to review")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tap to materialize one at a time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func pendingTemplates() -> [RecurrenceTemplate] {
        // Reuse the service-layer filter — keeps the rules in one place.
        RecurrenceService.pendingMaterializations(context: modelContext)
    }
}

/// Value-type that uniquely identifies the navigation destination for the
/// pending-materializations list. Lives separately from `InvoicesView.NavigationTarget`
/// because the catch-up banner pushes onto whichever NavigationStack is hosting
/// the Today view, not the Invoices stack.
struct PendingMaterializationsLink: Hashable {}
