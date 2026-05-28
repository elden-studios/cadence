import SwiftUI
import SwiftData
import BillableCore

/// Persistent bar shown above the tab bar whenever a timer is running.
/// Tapping it expands the full `RunningTimerCard` in a sheet. Renders nothing
/// when idle (the host attaches it via `.safeAreaInset`, so nothing = no inset).
struct FloatingTimerBar: View {
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]
    @Query private var profiles: [BusinessProfile]
    @Environment(\.modelContext) private var modelContext

    @State private var expanded = false
    @State private var showingSwitchSheet = false

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        if let running = runningEntries.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                bar(running, asOf: context.date)
            }
            .sheet(isPresented: $expanded) {
                expandedSheet(running)
            }
            .sheet(isPresented: $showingSwitchSheet) {
                StartTimerSheet(isSwitching: true)
            }
        }
    }

    private func bar(_ entry: TimeEntry, asOf: Date) -> some View {
        let accent = entry.isOnBreak ? Color.orange : Color.green
        return Button { expanded = true } label: {
            HStack(spacing: 10) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(entry.project?.name ?? "Timer")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(elapsedString(entry, asOf: asOf))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private func expandedSheet(_ entry: TimeEntry) -> some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningTimerCard(
                    entry: entry, asOf: context.date, currencyCode: currencyCode,
                    onStop: { TimerActions.stop(in: modelContext); expanded = false },
                    onSwitch: { expanded = false; showingSwitchSheet = true },
                    onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                    onResume: { TimerActions.resume(in: modelContext) }
                )
                .id(entry.persistentModelID)
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func elapsedString(_ entry: TimeEntry, asOf: Date) -> String {
        let seconds = Int(entry.duration(asOf: asOf))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
