import SwiftUI
import SwiftData
import BillableCore

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allClients: [Client]
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
    /// Bounded probe: does at least one non-archived client-linked project exist?
    /// Mirrors `GetStartedSection.anyLinkedProjectDescriptor` — same predicate,
    /// used here so `guidanceElement` can dismiss get-started the moment setup is
    /// reached in-session (before the maintenance-pass stamps `firstSetupCompletedAt`).
    @Query(Self.anyLinkedProjectDescriptor) private var linkedProjectProbe: [Project]

    private static var anyLinkedProjectDescriptor: FetchDescriptor<Project> {
        var d = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        d.fetchLimit = 1
        return d
    }

    @State private var showingManualEntry = false
    @State private var showingStartTimer = false
    @State private var enrichmentSnoozedThisSession = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    CatchUpBanner()
                        .padding(.horizontal)
                        .padding(.top, 4)
                    guidanceSection
                    JumpBackInSection(
                        showEmptyCTA: guidanceElement != .getStarted,
                        onStartTimer: { showingStartTimer = true }
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
                    Menu {
                        Button {
                            showingStartTimer = true
                        } label: {
                            Label("Start timer", systemImage: "play.fill")
                        }
                        Button {
                            showingManualEntry = true
                        } label: {
                            Label("Add past entry", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add entry")
                }
#if DEBUG
                if allClients.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Seed demo") {
                            SampleData.seedDemo(in: modelContext)
                        }
                    }
                }
#endif
            }
            .sheet(isPresented: $showingStartTimer) {
                StartTimerSheet(isSwitching: false)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheet()
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
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    private var profile: BusinessProfile? { profiles.first }

    /// The single guidance element for Today, resolved by the pure
    /// `TodayGuidance`. Inputs are derived here (the resolver never touches
    /// SwiftData). Get-started is gated on onboarding being complete AND
    /// first-setup not yet reached.
    private var guidanceElement: TodayGuidance.Element {
        let onboarded = profile?.onboardingCompletedAt != nil
        // Before onboarding completes, suppress get-started/enrichment entirely
        // (RootView is showing the onboarding screen anyway); only the rare
        // name-missing banner can apply.
        //
        // hasActiveSetup is true when EITHER:
        //   (a) the durable latch has been stamped (persists across launches), OR
        //   (b) the live @Query signals show setup is already reached this session
        //       (a client exists AND a client-linked non-archived project exists).
        // Case (b) handles the gap between in-app completion and the next
        // maintenance-pass that stamps `firstSetupCompletedAt`, so the
        // get-started card dismisses immediately rather than lingering until the
        // next foreground/launch. Once stamped, (a) takes over permanently.
        let stampedSetup = profile?.firstSetupCompletedAt != nil
        let liveSetup = !allClients.isEmpty && !linkedProjectProbe.isEmpty
        let hasActiveSetup = onboarded ? (stampedSetup || liveSetup) : true
        return TodayGuidance.resolve(
            hasName: BusinessProfile.canSendInvoice(profile: profile),
            hasActiveSetup: hasActiveSetup,
            isEnriched: profile?.isProfileEnriched ?? false,
            enrichmentSnoozed: enrichmentSnoozedThisSession
        )
    }

    @ViewBuilder
    private var guidanceSection: some View {
        switch guidanceElement {
        case .nameBanner:
            nameBanner
        case .getStarted:
            GetStartedSection(clients: allClients)
                .padding(.horizontal)
        case .enrichment:
            enrichmentNudge
        case .none:
            EmptyView()
        }
    }

    private var nameBanner: some View {
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

    /// §7b SECONDARY Today nudge (tier 3): an info card. "Not now" is
    /// session-only — no persisted flag. `isProfileEnriched` is the durable
    /// driver; the card returns next launch if the profile is still incomplete.
    private var enrichmentNudge: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(destination: BusinessProfileEditorView()) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finish your invoice details")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Add your address, bank details, and logo so invoices look professional.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                enrichmentSnoozedThisSession = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)        // ≥44pt touch target (spec §7b/§9)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

}

// MARK: - Running Timer Section

// MARK: - Jump Back In

private struct JumpBackInSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
    @Query(Self.recentDescriptor) private var recentEntries: [TimeEntry]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    /// When `true` and there are no recent projects, render a "Start a timer"
    /// CTA instead of rendering nothing. Callers pass `false` when a
    /// get-started card already occupies the guidance slot.
    var showEmptyCTA: Bool = false
    /// Called when the user taps the empty-state CTA.
    var onStartTimer: () -> Void = {}

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        // `runningProjectID` reads .project; prefetch it to avoid a lazy fault.
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private static var recentDescriptor: FetchDescriptor<TimeEntry> {
        // No `Date.now` predicate here: a @Query captures the descriptor once at
        // view-init, which would freeze the cutoff. Instead fetch the most-recent
        // entries (bounded) and apply a fresh sliding cutoff in `recents`.
        var d = FetchDescriptor<TimeEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        d.fetchLimit = 200
        // Prefetch ONLY the project hop. A nested keypath (\.project?.client)
        // TRAPS on the CloudKit-backed store: SwiftData's
        // Schema.KeyPathCache.validateAndCache hits assertionFailure while
        // converting the fetch request's keypaths to strings (crash in build
        // 2026060101, Today → "Jump back in"). The local store tolerates it,
        // which is why it only crashed on real installs. RecentProjects.rank
        // faults project.client lazily — fine for the bounded 200-entry window.
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    private var recents: [Project] {
        // 60-day sliding window (wider than StartTimerSheet's 30-day), applied
        // with a fresh `Date.now` each render so it isn't frozen at view init.
        // Calendar day math (not raw seconds) to stay correct across DST.
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now
        return RecentProjects.rank(from: recentEntries.filter { $0.startedAt > cutoff }, limit: 5)
    }

    /// The running project's ID (if any), via one named accessor instead of
    /// re-traversing the running entry's relationship per card.
    private var runningProjectID: PersistentIdentifier? {
        runningEntries.first?.project?.persistentModelID
    }

    private func isThisProjectRunning(_ project: Project) -> Bool {
        runningProjectID == project.persistentModelID
    }

    var body: some View {
        let projects = recents   // compute once per render (used twice below)
        return Group {
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Jump back in")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(projects) { project in
                                card(project)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    // Cancel the parent's horizontal padding so cards scroll
                    // edge-to-edge, while the inner padding keeps the initial inset.
                    .padding(.horizontal, -16)
                }
            } else if showEmptyCTA {
                Button(action: onStartTimer) {
                    Label("Start a timer", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.timerAccent)
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
                if let runningProjectID,
                   runningProjectID != project.persistentModelID {
                    TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                } else {
                    TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                }
            } label: {
                Image(systemName: isThisProjectRunning(project) ? "waveform" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        (isThisProjectRunning(project) ? .green : .timerAccent),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .disabled(isThisProjectRunning(project))
            .accessibilityLabel(isThisProjectRunning(project) ? "Running" : "Start timer")
            .padding(10)
        }
    }
}

// MARK: - Summary numbers

private struct TodaySummarySection: View {
    // todayEntries (today's Hours/Earnings): predicate-bounded to startOfDay so future-dated
    // entries cannot inflate today's figures and today's entries are always present regardless
    // of how many future-dated rows exist. The live isDate(inSameDayAs:) filter in
    // content(asOf:) is kept as-is so midnight rollover works correctly.
    @Query(Self.todayFloorDescriptor) private var todayEntries: [TimeEntry]

    // uninvoicedEntries (Uninvoiced amount): predicate-filtered to invoiceID == nil only.
    // Running entries have invoiceID == nil so the live-ticking running entry is included.
    // Uses a static descriptor with \.project prefetch to avoid N+1 faults on every
    // per-second tick (amount(asOf:) reads entry.project for the hourly rate).
    @Query(Self.uninvoicedDescriptor) private var uninvoicedEntries: [TimeEntry]

    let currencyCode: String

    @State private var showingGenerator = false

    private static var uninvoicedDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.invoiceID == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private static var todayFloorDescriptor: FetchDescriptor<TimeEntry> {
        // Predicate-bounded to startOfDay so only today-onward entries are fetched
        // (typically a handful). No fetchLimit or sort needed — the reduce in
        // content(asOf:) doesn't require ordering and the set is small.
        let startOfDay = Calendar.current.startOfDay(for: .now)
        var d = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startedAt >= startOfDay }
        )
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(asOf: context.date)
        }
        .sheet(isPresented: $showingGenerator) {
            InvoiceGeneratorView()
        }
    }

    @ViewBuilder
    private func content(asOf referenceDate: Date) -> some View {
        let cal = Calendar.current
        let todays = todayEntries.filter { entry in
            cal.isDate(entry.startedAt, inSameDayAs: referenceDate)
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            acc += e.duration(asOf: referenceDate)   // worked time, breaks excluded
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            acc += e.amount(asOf: referenceDate)      // uses duration() internally
        }
        let uninvoiced = uninvoicedEntries
            .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: referenceDate) }

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Today").font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    SummaryTile(label: "Hours", value: DurationFormatting.hoursMinutes(seconds: todaysSeconds), color: .blue)
                    SummaryTile(label: "Earnings", value: todaysAmount.formatted(.currency(code: currencyCode)), color: .green)
                }
            }
            if uninvoiced > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ready to invoice").font(.title3.weight(.semibold))
                    UninvoicedTile(amount: uninvoiced, currency: currencyCode, onTap: { showingGenerator = true })
                }
            }
        }
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            tileBody
        }
        .buttonStyle(.plain)
    }

    private var tileBody: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(amount.formatted(.currency(code: currency)))
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                Text("Hours you've tracked but haven't invoiced yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }
}
