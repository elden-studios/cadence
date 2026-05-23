import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

/// List of templates whose `nextFireDate` is in the past. Tapping a row
/// materializes a single template into a Draft invoice and either:
/// - succeeds → pops back to Today (the row disappears from the list because
///   the service advances `nextFireDate` past `now`)
/// - fails → shows an inline error
///
/// Materializing one at a time is intentional: it forces the user to
/// acknowledge each pending occurrence rather than batch-creating drafts.
struct PendingMaterializationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var materializingID: UUID?
    @State private var errorMessage: String?

    @Query(sort: \RecurrenceTemplate.nextFireDate) private var allTemplates: [RecurrenceTemplate]

    var body: some View {
        Group {
            if pending().isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.seal",
                    description: Text("No recurring invoices waiting for review.")
                )
            } else {
                List {
                    Section {
                        ForEach(pending(), id: \.id) { template in
                            Button {
                                Task { await materialize(template) }
                            } label: {
                                row(template)
                            }
                            .disabled(materializingID != nil)
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Catch up")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ template: RecurrenceTemplate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.client?.name ?? "—").font(.headline)
                Text("Was due \(template.nextFireDate.formatted(.dateTime.month().day()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if materializingID == template.id {
                ProgressView()
            } else {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func pending() -> [RecurrenceTemplate] {
        RecurrenceService.pendingMaterializations(context: modelContext)
    }

    @MainActor
    private func materialize(_ template: RecurrenceTemplate) async {
        materializingID = template.id
        defer { materializingID = nil }
        do {
            let scheduler = Scheduler(
                center: UNUserNotificationCenter.current(),
                modelContext: modelContext
            )
            _ = try RecurrenceService.materializeDraft(
                template: template, now: .now, context: modelContext, scheduler: scheduler
            )
            errorMessage = nil
        } catch RecurrenceService.MaterializationError.noBusinessProfile {
            errorMessage = "Set up your business profile first."
        } catch RecurrenceService.MaterializationError.noClient {
            errorMessage = "This template's client was deleted. Open the editor to remove it."
        } catch RecurrenceService.MaterializationError.ended {
            errorMessage = "This template has ended."
        } catch {
            errorMessage = "Couldn't generate: \(error.localizedDescription)"
        }
    }
}
