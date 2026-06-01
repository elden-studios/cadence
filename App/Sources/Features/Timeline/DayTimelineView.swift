import SwiftUI
import SwiftData
import BillableCore

/// The wedge UX: a vertical 24-hour day canvas with `TimeEntry` blocks
/// that can be dragged to shift, resized at either edge, and split / deleted
/// via a context menu.
struct DayTimelineView: View {
    let day: Date
    let snap: TimelineSnap

    @Environment(\.modelContext) private var modelContext
    @Query private var allEntries: [TimeEntry]

    @State private var activeDrag: ActiveDrag?
    @State private var selectedEntry: TimeEntry?

    private let leftGutter: CGFloat = 56
    private let blockRightPadding: CGFloat = 12

    init(day: Date, snap: TimelineSnap = .fifteenMinutes) {
        self.day = day
        self.snap = snap
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = #Predicate<TimeEntry> { entry in
            entry.startedAt < end && (entry.endedAt ?? end) > start
        }
        _allEntries = Query(filter: predicate, sort: \TimeEntry.startedAt)
    }

    private var geometry: TimelineGeometry {
        TimelineGeometry(dayStart: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        GeometryReader { proxy in
            let canvasWidth = proxy.size.width
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    if needsLiveTick {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            canvas(width: canvasWidth, referenceDate: ctx.date)
                        }
                    } else {
                        canvas(width: canvasWidth, referenceDate: .now)
                    }
                }
                .background(Color(.systemBackground))
                .onAppear { scrollToInterestingHour(scroller) }
                .onChange(of: day) { scrollToInterestingHour(scroller) }
                .sheet(item: $selectedEntry) { entry in
                    ManualEntrySheet(editing: entry)
                }
            }
        }
    }

    /// True when (a) we're viewing today AND (b) there's a running entry,
    /// so the running block's bottom edge and the current-time indicator need
    /// to track the clock at ~1Hz. Off otherwise to save CPU.
    private var needsLiveTick: Bool {
        Calendar.current.isDateInToday(day) && allEntries.contains { $0.isRunning }
    }

    @ViewBuilder
    private func canvas(width canvasWidth: CGFloat, referenceDate: Date) -> some View {
        ZStack(alignment: .topLeading) {
            hourGrid(width: canvasWidth)
            blocksLayer(canvasWidth: canvasWidth, referenceDate: referenceDate)
            if Calendar.current.isDateInToday(day) {
                currentTimeIndicator(width: canvasWidth, referenceDate: referenceDate)
            }
        }
        .frame(width: canvasWidth, height: geometry.totalHeight, alignment: .topLeading)
    }

    /// Scroll target on first appearance: the first entry of the day if any,
    /// otherwise the current hour, otherwise 8 AM.
    private func scrollToInterestingHour(_ scroller: ScrollViewProxy) {
        let cal = Calendar.current
        let targetDate: Date = {
            if let first = allEntries.first { return first.startedAt }
            if cal.isDateInToday(day) { return Date.now }
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        }()
        let hour = cal.component(.hour, from: targetDate)
        // Scroll one hour above the target so the entry has breathing room
        let anchor = max(0, hour - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.snappy) { scroller.scrollTo(anchor, anchor: .top) }
        }
    }

    // MARK: - Hour grid

    private func hourGrid(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: leftGutter - 8, alignment: .trailing)
                        .padding(.trailing, 4)
                        .offset(y: -7)
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.gray.opacity(hour == 0 ? 0 : 0.18))
                            .frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: width, height: geometry.pointsPerHour, alignment: .topLeading)
                .id(hour)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        guard let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) else {
            return "\(hour)"
        }
        return formatter.string(from: date)
    }

    // MARK: - Current time

    private func currentTimeIndicator(width: CGFloat, referenceDate: Date) -> some View {
        let y = geometry.y(for: referenceDate)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: width - leftGutter + 8, height: 1)
                .offset(x: leftGutter - 8)
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .offset(x: leftGutter - 12)
        }
        .frame(width: width, alignment: .leading)
        .offset(y: y - 0.5)
        .allowsHitTesting(false)
    }

    // MARK: - Entry blocks

    private func blocksLayer(canvasWidth: CGFloat, referenceDate: Date) -> some View {
        let blockX = leftGutter
        let blockWidth = max(50, canvasWidth - leftGutter - blockRightPadding)

        return ZStack(alignment: .topLeading) {
            ForEach(allEntries) { entry in
                let layout = visualLayout(for: entry, referenceDate: referenceDate)
                TimeBlockView(
                    height: layout.height,
                    title: entry.project?.name ?? "Untitled",
                    subtitle: timeRangeLabel(for: entry),
                    color: entry.project?.client?.color.swiftUIColor ?? .blue,
                    isSelected: isSelected(entry),
                    isRunning: entry.isWorking,
                    onDrag: { mode, delta in
                        activeDrag = ActiveDrag(
                            entryID: entry.persistentModelID,
                            mode: mode,
                            deltaPoints: delta
                        )
                    },
                    onDragEnd: { _ in
                        commitActiveDrag(for: entry)
                    },
                    onTap: { selectedEntry = entry },
                    onLongPress: { selectedEntry = entry }
                )
                .frame(width: blockWidth, height: layout.height)
                .offset(x: blockX, y: layout.y)
                .contextMenu { blockContextMenu(for: entry) }
            }
        }
        .frame(width: canvasWidth, height: geometry.totalHeight, alignment: .topLeading)
    }

    private func isSelected(_ entry: TimeEntry) -> Bool {
        guard let selected = selectedEntry else { return false }
        return selected.persistentModelID == entry.persistentModelID
    }

    private func blockContextMenu(for entry: TimeEntry) -> some View {
        Group {
            // A running session is managed from the Today / running-timer card, not
            // mutated here. Split/Duplicate only apply to a finished span (they no-op
            // on a live entry), and a raw Delete of the running entry would bypass
            // TimerActions.stop and ORPHAN the Live Activity (it would tick forever and
            // re-adopt on next launch with no backing entry). So gate the mutating
            // actions on a finished entry — consistent with ManualEntrySheet's
            // running-entry guard and the `endedAt != nil` guards in splitInHalf /
            // duplicate / commitActiveDrag above. Edit stays available: it opens
            // ManualEntrySheet, which blocks Save with a "stop the timer first" hint.
            Button("Edit") { selectedEntry = entry }
            if !entry.isRunning {
                Button("Split here") { splitInHalf(entry) }
                Button("Duplicate") { duplicate(entry) }
                Button("Delete", role: .destructive) { delete(entry) }
            }
        }
    }

    private func visualLayout(for entry: TimeEntry, referenceDate: Date) -> (y: CGFloat, height: CGFloat) {
        let start = entry.startedAt
        let end = entry.endedAt ?? clampedDayEnd(referenceDate: referenceDate)
        var startY = geometry.y(for: start)
        var endY = geometry.y(for: end)

        if let drag = activeDrag, drag.entryID == entry.persistentModelID {
            switch drag.mode {
            case .translate:
                startY += drag.deltaPoints
                endY += drag.deltaPoints
            case .resizeTop:
                startY = min(endY - 20, startY + drag.deltaPoints)
            case .resizeBottom:
                endY = max(startY + 20, endY + drag.deltaPoints)
            }
        }
        return (max(0, startY), max(20, endY - startY))
    }

    private func clampedDayEnd(referenceDate: Date) -> Date {
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: geometry.dayStart) ?? referenceDate
        return min(referenceDate, endOfDay)
    }

    private func timeRangeLabel(for entry: TimeEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let start = formatter.string(from: entry.startedAt)
        let end = entry.endedAt.map(formatter.string(from:)) ?? "now"
        return "\(start) – \(end)"
    }

    // MARK: - Drag commit

    private func commitActiveDrag(for entry: TimeEntry) {
        defer { activeDrag = nil }
        guard let drag = activeDrag, drag.entryID == entry.persistentModelID else { return }
        // Only finished entries are editable on the timeline; live sessions are
        // managed via the Today card.
        guard entry.endedAt != nil else { return }

        let deltaSeconds = TimeInterval(drag.deltaPoints / geometry.pointsPerSecond)

        switch drag.mode {
        case .translate:
            let newStart = entry.startedAt.addingTimeInterval(deltaSeconds)
            let newEnd = (entry.endedAt ?? Date.now).addingTimeInterval(deltaSeconds)
            entry.startedAt = geometry.snap(newStart, toMinutes: snap.rawValue)
            entry.endedAt = entry.endedAt.map { _ in geometry.snap(newEnd, toMinutes: snap.rawValue) }
        case .resizeTop:
            let proposed = entry.startedAt.addingTimeInterval(deltaSeconds)
            let snapped = geometry.snap(proposed, toMinutes: snap.rawValue)
            let limit = (entry.endedAt ?? Date.now).addingTimeInterval(-60)
            if snapped < limit { entry.startedAt = snapped }
        case .resizeBottom:
            let currentEnd = entry.endedAt ?? Date.now
            let proposed = currentEnd.addingTimeInterval(deltaSeconds)
            let snapped = geometry.snap(proposed, toMinutes: snap.rawValue)
            if snapped > entry.startedAt.addingTimeInterval(60) {
                entry.endedAt = snapped
            }
        }
        // Geometry was changed manually — flatten banked breaks so duration()
        // falls back to the new wall-clock span (endedAt − startedAt).
        entry.accumulatedSeconds = 0
        entry.updatedAt = .now
        modelContext.saveOrLog("drag/resize entry")
    }

    // MARK: - Context menu actions

    private func splitInHalf(_ entry: TimeEntry) {
        guard let endedAt = entry.endedAt else { return }
        let midpoint = entry.startedAt.addingTimeInterval(endedAt.timeIntervalSince(entry.startedAt) / 2)
        let snapped = geometry.snap(midpoint, toMinutes: snap.rawValue)
        guard snapped > entry.startedAt.addingTimeInterval(60),
              snapped < endedAt.addingTimeInterval(-60) else { return }

        // New entry always has accumulatedSeconds == 0 by default.
        let second = TimeEntry(
            startedAt: snapped,
            endedAt: endedAt,
            notes: entry.notes,
            isManual: true,
            project: entry.project
        )
        entry.endedAt = snapped
        // Flatten the original entry: geometry changed, duration() should use
        // the new wall-clock span (endedAt − startedAt).
        entry.accumulatedSeconds = 0
        entry.updatedAt = .now
        modelContext.insert(second)
        modelContext.saveOrLog("split entry")
    }

    private func duplicate(_ entry: TimeEntry) {
        guard let endedAt = entry.endedAt else { return }
        let duration = endedAt.timeIntervalSince(entry.startedAt)
        let newStart = endedAt
        let newEnd = newStart.addingTimeInterval(duration)
        let copy = TimeEntry(
            startedAt: newStart,
            endedAt: newEnd,
            notes: entry.notes,
            isManual: true,
            project: entry.project
        )
        modelContext.insert(copy)
        modelContext.saveOrLog("duplicate entry")
    }

    private func delete(_ entry: TimeEntry) {
        // Defense-in-depth (the context menu already hides Delete for a running
        // entry): never raw-delete a live session here — it bypasses
        // TimerActions.stop and orphans the Live Activity. `!isRunning` mirrors
        // the context-menu gate for this same Delete action (delete never
        // consumes endedAt as a value, unlike splitInHalf / duplicate /
        // commitActiveDrag, so the intent is purely "reject a live session").
        guard !entry.isRunning else { return }
        // Clear selection BEFORE deleting: long-press to open the context menu
        // also sets `selectedEntry` (TimeBlockView.onLongPress / onTap), so
        // without this the @State binding would point at a deleted model —
        // isSelected reads its persistentModelID and .sheet(item:) could
        // re-present an invalidated entry (stale UI / SwiftData crash). Niling
        // also dismisses the edit sheet if open, which is desired since the
        // entry is gone.
        if selectedEntry?.persistentModelID == entry.persistentModelID {
            selectedEntry = nil
        }
        modelContext.delete(entry)
        modelContext.saveOrLog("delete entry")
    }
}

private struct ActiveDrag: Equatable {
    let entryID: PersistentIdentifier
    let mode: TimeBlockView.DragMode
    let deltaPoints: CGFloat
}

extension TimeBlockView.DragMode: Equatable {}
