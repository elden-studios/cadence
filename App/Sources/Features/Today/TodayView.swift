import SwiftUI
import SwiftData
import BillableCore

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allClients: [Client]
    @Query private var profiles: [BusinessProfile]

    @State private var showingStartSheet = false
    @State private var showingSwitchSheet = false
    @State private var showingManualEntry = false
    @State private var editingEntry: TimeEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    CatchUpBanner()
                        .padding(.horizontal)
                        .padding(.top, 4)
                    if showEmptyBusinessBanner {
                        NavigationLink(destination: BusinessProfileEditorView()) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Add your business name to send invoices")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    TodayActiveTimerSection(
                        currencyCode: currencyCode,
                        onStop: stopRunning,
                        onSwitch: { showingSwitchSheet = true },
                        onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                        onResume: { TimerActions.resume(in: modelContext) },
                        onStart: { showingStartSheet = true }
                    )
                    TodaySummarySection(currencyCode: currencyCode)
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: PendingMaterializationsLink.self) { _ in
                PendingMaterializationsView()
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        TimelineScreen(day: .now)
                    } label: {
                        Image(systemName: "calendar.day.timeline.left")
                    }
                    .accessibilityLabel("Open timeline")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingManualEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add past entry")
                }
                if allClients.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Seed demo") {
                            SampleData.seedDemo(in: modelContext)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingStartSheet) {
                StartTimerSheet(isSwitching: false)
            }
            .sheet(isPresented: $showingSwitchSheet) {
                StartTimerSheet(isSwitching: true)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheet()
            }
            .sheet(item: $editingEntry) { entry in
                ManualEntrySheet(editing: entry)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Date.now.formatted(.dateTime.month().day()))
                .font(.largeTitle.weight(.bold))
        }
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? "USD"
    }

    private var showEmptyBusinessBanner: Bool {
        !BusinessProfile.canSendInvoice(profile: profiles.first)
    }

    private func stopRunning() {
        TimerActions.stop(in: modelContext)
    }

}

// MARK: - Active timer card

private struct TodayActiveTimerSection: View {
    @Query(Self.runningDescriptor)
    private var runningEntries: [TimeEntry]

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endedAt == nil }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
    let onTakeBreak: () -> Void
    let onResume: () -> Void
    let onStart: () -> Void

    var body: some View {
        Group {
            if let running = runningEntries.first {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    RunningTimerCard(
                        entry: running, asOf: context.date, currencyCode: currencyCode,
                        onStop: onStop, onSwitch: onSwitch, onTakeBreak: onTakeBreak, onResume: onResume
                    )
                    // Tag identity by the running entry's persistent ID so that
                    // an atomic Switch (TimerService.switchTo stops the old
                    // entry and inserts a new one in one save) produces a
                    // FRESH view with fresh @State. Without this, the
                    // @State `lastSavedNotes` (debounce baseline) would
                    // persist from the OLD entry across into the NEW entry's
                    // lifetime and trigger a spurious save on the new entry's
                    // first .task fire (its notes are nil but the baseline
                    // remembers the old entry's saved value).
                    .id(running.persistentModelID)
                }
            } else {
                IdleTimerCard(onStart: onStart)
            }
        }
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.persistentModelID)
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.activeSegmentStartedAt)
    }
}


private struct IdleTimerCard: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("00:00:00")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
            Text("No timer running").font(.subheadline).foregroundStyle(.secondary)
            Button(action: onStart) {
                Label("Start timer", systemImage: "play.fill")
            }
            .buttonStyle(TimerPrimaryButtonStyle(tint: timerAccent))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(TimerCardSurface())
    }
}

// MARK: - Summary numbers

private struct TodaySummarySection: View {
    @Query(Self.entriesDescriptor) private var allEntries: [TimeEntry]
    let currencyCode: String

    private static var entriesDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>()
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(asOf: context.date)
        }
    }

    @ViewBuilder
    private func content(asOf referenceDate: Date) -> some View {
        let cal = Calendar.current
        let todays = allEntries.filter { entry in
            cal.isDate(entry.startedAt, inSameDayAs: referenceDate)
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            acc += e.duration(asOf: referenceDate)   // worked time, breaks excluded
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            acc += e.amount(asOf: referenceDate)      // uses duration() internally
        }
        let uninvoiced = allEntries
            .filter { $0.invoiceID == nil }
            .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: referenceDate) }

        VStack(alignment: .leading, spacing: 14) {
            Text("Today")
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                SummaryTile(label: "Hours", value: formatHours(todaysSeconds), color: .blue)
                SummaryTile(
                    label: "Earnings",
                    value: todaysAmount.formatted(.currency(code: currencyCode)),
                    color: .green
                )
            }
            UninvoicedTile(amount: uninvoiced, currency: currencyCode)
        }
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }
}

private struct UninvoicedTile: View {
    let amount: Decimal
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNINVOICED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(amount.formatted(.currency(code: currency)))
                .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
            Text("Hours you've tracked but haven't invoiced yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }
}
