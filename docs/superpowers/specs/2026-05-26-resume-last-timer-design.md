# Cadence — "Resume Last" Quick Action

**Status:** Design approved · ready for implementation plan
**Date:** 2026-05-26
**Phase:** v1.3 candidate (post-v1.2)
**Estimated scope:** ~2-3 hours
**Spec author session:** brainstorming flow (superpowers:brainstorming)

---

## 1. Summary

Add a "Resume" quick action to Today so freelancers can pick up where they left off after a short interruption (coffee, phone call, bathroom break) without manually navigating "Start timer → Pick Client → Pick Project."

After stopping a timer, a muted "▶ Resume Acme Corp · Project X" pill appears on Today for up to 60 minutes (or until midnight, whichever comes first). Tapping it creates a new TimeEntry with the same client + project metadata as the most recently stopped entry. The Timeline reflects reality: two contiguous blocks with the actual gap between them visible.

**No new @Model, no schema migration.** The pill is computed from a `@Query` over the most recent stopped TimeEntry.

---

## 2. Goals & non-goals

### Goals
- Solve the "I was interrupted for 5 minutes, now I want to keep tracking the same thing" scenario with 1 tap.
- Keep the data model honest — separate TimeEntries with a visible gap in the Timeline.
- Rely on the invoice generator's existing line-item grouping (adjacent same-client-project entries within a window collapse into a single line item — verify this assumption during implementation; if absent, add a simple grouping rule).
- Solve this entirely within `TodayView` + a small static helper. No new @Model.

### Non-goals (deferred)
- **Pause/Resume on the entry itself** (Approach B + C from the brainstorm) — rejected. Would either misrepresent the Timeline (one block hiding gaps) OR require a multi-interval model that doesn't fit Cadence's "contiguous billable blocks" philosophy.
- **Multi-step undo on the resume action** — if the user taps Resume by accident, they can just Stop the new entry. No undo stack needed.
- **Cross-day continuation** — if you stopped before midnight and want to "resume" tomorrow morning, you can manually use Start Timer with the same client/project. Cross-midnight resume is out of scope.
- **Resume from any historical entry** (not just the most recent) — out of scope. The pill targets the most recent stopped entry only.

---

## 3. Design

### Pill visibility — `shouldShowResumePill(lastStopped:now:)`

A static helper, testable in isolation. Returns `true` iff:
1. `lastStopped` is non-nil
2. `lastStopped.endedAt != nil` (actually stopped, not running)
3. `lastStopped.client != nil` (has a client to resume into)
4. `now.timeIntervalSince(lastStopped.endedAt!) < 60 * 60` (within 60 min)
5. `Calendar.current.isDate(now, inSameDayAs: lastStopped.endedAt!)` (same calendar day)

If any condition fails → no pill.

Signature:

```swift
extension TimeEntry {
    /// Pure function — testable without view scaffolding.
    static func shouldShowResumePill(
        lastStopped: TimeEntry?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let entry = lastStopped,
              let endedAt = entry.endedAt,
              entry.client != nil else { return false }
        let secondsSince = now.timeIntervalSince(endedAt)
        guard secondsSince < 60 * 60 else { return false }
        guard calendar.isDate(now, inSameDayAs: endedAt) else { return false }
        return true
    }
}
```

### TodayView integration

Add a `@Query` for the most recent stopped TimeEntry:

```swift
@Query(
    filter: #Predicate<TimeEntry> { $0.endedAt != nil },
    sort: \TimeEntry.endedAt,
    order: .reverse,
    fetchLimit: 1
)
private var mostRecentStoppedEntries: [TimeEntry]

private var lastStopped: TimeEntry? { mostRecentStoppedEntries.first }
```

(Verify SwiftData's `@Query` supports `fetchLimit` — if not, fetch all and take `.first` from the sorted array. Acceptable since SwiftData should optimize the underlying fetch.)

Already on TodayView (from earlier work): the `@Query` for active timer (`endedAt == nil`). When that query returns empty (no running timer), conditionally render the resume pill:

```swift
// In the TodayView body, after the active-timer card section:
if running == nil {  // no currently running timer
    let now = Date.now  // or use TimelineView for live updating
    if TimeEntry.shouldShowResumePill(lastStopped: lastStopped, now: now),
       let last = lastStopped,
       let client = last.client,
       let project = last.project {
        ResumePill(client: client, project: project) {
            resumeLastTimer(client: client, project: project)
        }
    }
}
```

### ResumePill view

A small subview in `TodayView.swift`:

```swift
private struct ResumePill: View {
    let client: Client
    let project: Project
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
                Circle()
                    .fill(client.color.swiftUIColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resume \(client.name) · \(project.name)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Continue tracking where you left off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}
```

(Match the visual style of other Today pills/banners — `secondarySystemBackground` + 12pt corner radius.)

### `resumeLastTimer(client:project:)` action

```swift
private func resumeLastTimer(client: Client, project: Project) {
    let entry = TimeEntry(
        client: client,
        project: project,
        startedAt: .now,
        endedAt: nil
    )
    modelContext.insert(entry)
    try? modelContext.save()
    // Optional: trigger Live Activity start via existing TimerActivityController
}
```

This is the same code path the existing "+ Start timer" sheet uses on Submit — so leverage that helper if already factored out.

---

## 4. Schema / data model

**No changes.** No new `@Model`, no new fields. The pill is purely a computed UI affordance over existing `TimeEntry` data.

---

## 5. Test plan

### Unit tests
- `ResumePillVisibilityTests.swift` — covers `shouldShowResumePill` in isolation:
  - `nil` last entry → false
  - Last entry has no client → false
  - Last entry stopped 30 min ago, same day → true
  - Last entry stopped 90 min ago, same day → false (over the window)
  - Last entry stopped 30 min ago, yesterday → false (crossed midnight)
  - Last entry is still running (`endedAt == nil`) → false

### Integration test (light)
- A test that constructs a `ModelContext` with one stopped TimeEntry, runs the @Query, and confirms `lastStopped` matches.
- (No need for a full UI test — the static helper has the logic.)

### Manual smoke
- Stop a timer → confirm the pill appears below the timer area.
- Tap it → confirm a new TimeEntry is created with same client + project, the pill disappears, the running timer card appears.
- Wait 65 minutes → confirm the pill disappears.

---

## 6. Risks

1. **The `@Query` for the most recent stopped entry could be slow with many entries.** Mitigation: SwiftData should index by `endedAt`. If profiling shows slowness, add an explicit index or constrain to "today's entries only."
2. **`fetchLimit` in @Query** — if SwiftData doesn't support it cleanly, fall back to fetching all and taking `.first`. Either way, the read is cheap.
3. **Cross-time-zone edge case** — `isDate(inSameDayAs:)` uses `Calendar.current`, which respects the user's time zone. If the user crosses time zones mid-day with a stopped entry, the "same day" check might surprise them. Acceptable for v1.3.
4. **Two stopped entries within a minute of each other** — the @Query picks the absolute most-recent. If the user stopped 30s ago and another 35s ago, Resume always targets the 30s-ago one. Correct behavior.

---

## 7. Acceptance criteria

1. ✅ Stop a timer → "Resume Acme Corp · Project X" pill appears on Today within 1 frame.
2. ✅ Tap the pill → new TimeEntry created with same client + project; timer card appears; pill disappears.
3. ✅ Wait > 60 min after stop → pill no longer visible.
4. ✅ Cross midnight after stop → pill no longer visible (next morning, no pill).
5. ✅ Currently running timer → pill hidden.
6. ✅ Last stopped entry has no client (data corruption edge case) → pill hidden.
7. ✅ Unit tests cover the 5 edge cases for `shouldShowResumePill`.
8. ✅ All existing 147 BillableCore tests still pass.

---

## 8. Out of scope (deferred to later releases)

- Pause/Resume on the entry itself (multi-interval model or accumulated pause duration)
- Cross-day resume
- Multi-entry resume picker ("resume from any of the last 3 entries")
- Resume button on the Timeline editor (only on Today)
- Live Activity wake-up when pill becomes available

---

## 9. Approval

Ready for the plan-writing skill (`superpowers:writing-plans`). Estimated ~3-4 plan tasks: helper + tests, @Query + pill view, action wiring, smoke.

**User confirmed during brainstorm:**
- Approach A (Resume Last, not Pause on entry) — approved
- Wording: "Resume" — approved
- 60-min freshness window — approved
- Pill placement: below timer card area — approved
