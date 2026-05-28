import SwiftUI
import SwiftData
import BillableCore

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allClients: [Client]
    @Query private var profiles: [BusinessProfile]

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
                    JumpBackInSection()
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

}

// MARK: - Jump Back In

private struct JumpBackInSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query(Self.recentDescriptor) private var recentEntries: [TimeEntry]

    private static var recentDescriptor: FetchDescriptor<TimeEntry> {
        let cutoff = Date.now.addingTimeInterval(-60 * 24 * 3600)
        var d = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startedAt > cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    private var recents: [Project] {
        RecentProjects.rank(from: recentEntries, limit: 5)
    }

    var body: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jump back in")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recents) { project in
                            card(project)
                        }
                    }
                }
            }
        }
    }

    private func card(_ project: Project) -> some View {
        // ZStack (not a Button nested in the NavigationLink label) so the
        // play button and navigation are independent tap targets.
        ZStack(alignment: .topTrailing) {
            NavigationLink {
                ProjectDetailView(project: project)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Circle()
                        .fill(project.client?.color.swiftUIColor ?? .blue)
                        .frame(width: 10, height: 10)
                    Spacer(minLength: 16)
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let client = project.client {
                        Text(client.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 134, height: 104, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button {
                TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(red: 0.98, green: 0.49, blue: 0.13), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
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
