#if DEBUG
import SwiftUI
import SwiftData
import BillableCore

/// Internal QA readout of Tier-1 activation metrics (spec §14). DEBUG-only, computed
/// on-device from existing SwiftData via `ActivationMetrics` — nothing persisted, nothing
/// transmitted. Gated by `--debug-scheduler` in `SettingsView`, sibling to `DiagnosticsView`.
struct ActivationMetricsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot: ActivationMetrics.Snapshot?

    var body: some View {
        List {
            if let s = snapshot {
                Section {
                    LabeledContent("First-timer path", value: s.firstTimerKind.rawValue)
                    LabeledContent("Activation reached", value: s.activationReached ? "yes" : "no")
                } header: { Text("Headline") } footer: {
                    Text("quickStart = first timed entry on a clientless \u{201C}General\u{201D} project; checklist = client-linked. The direct read on the hybrid-onboarding bet.")
                }

                Section {
                    LabeledContent("Freelancer profiles", value: "\(s.freelancerCount)")
                    LabeledContent("Organization profiles", value: "\(s.organizationCount)")
                } header: { Text("Entity-type split") }

                Section {
                    LabeledContent("To first timer", value: format(s.timeToFirstTimer))
                    LabeledContent("To first project", value: format(s.timeToFirstProject))
                    LabeledContent("To first invoice", value: format(s.timeToFirstInvoice))
                } header: { Text("Time from onboarding") } footer: {
                    Text("Elapsed from onboardingCompletedAt to the earliest createdAt. \u{201C}\u{2014}\u{201D} means the milestone or the onboarding stamp is absent.")
                }
            } else {
                Text("Computing\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { snapshot = ActivationMetrics.compute(in: modelContext) }
    }

    /// Compact human duration; "—" for nil.
    private func format(_ interval: TimeInterval?) -> String {
        guard let interval else { return "\u{2014}" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: interval) ?? "\(Int(interval))s"
    }
}
#endif
