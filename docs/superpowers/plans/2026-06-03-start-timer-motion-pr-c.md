# Start-Timer Motion → Hero Morph Default (PR C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. (This PR is tiny + has no unit-testable logic — inline execution is fine.)

**Goal:** Ship **Hero Morph** as the start-timer (Start ↔ Running card) motion default and remove the DEBUG-only motion picker, leaving no dead code.

**Architecture:** `TimerMotionStyle` (in `RunningTimerCard.swift`) stays the motion abstraction `ProjectDetailView` consumes. Flip its `@AppStorage` default value **and** the decode fallback to `.heroMorph` (in `ProjectDetailView` — the sole reader after this PR); delete the DEBUG `@AppStorage` + the "Timer motion" picker `Section` in `SettingsView`; drop the now-orphaned picker-only enum members (`CaseIterable`/`Identifiable`/`id`/`label`/`blurb`). Pure SwiftUI + `@AppStorage`; no SwiftData/StoreKit. Not unit-testable (App-target views) → verified by a clean build + grep + a manual default check.

**Tech Stack:** Swift 6, SwiftUI, `@AppStorage`.

---

## File Structure
### Modified
- `App/Sources/Features/Projects/ProjectDetailView.swift` — `@AppStorage` motion default + decode fallback → `.heroMorph`.
- `App/Sources/Features/Settings/SettingsView.swift` — delete the DEBUG `@AppStorage timerMotionRaw` + the DEBUG "Timer motion" `Section`.
- `App/Sources/Features/Timer/RunningTimerCard.swift` — `TimerMotionStyle`: drop picker-only `CaseIterable`/`Identifiable` + `id`/`label`/`blurb`; refresh the stale doc comment. Keep the 3 cases + `storageKey` + `animation()`/`transition()`.

---

## Task 1: Default the motion to Hero Morph in ProjectDetailView

**Files:** Modify `App/Sources/Features/Projects/ProjectDetailView.swift:15-16`

- [ ] **Step 1: Flip the @AppStorage default + the decode fallback.** Replace:
```swift
    @AppStorage(TimerMotionStyle.storageKey) private var motionStyleRaw = TimerMotionStyle.spring.rawValue
    private var motionStyle: TimerMotionStyle { TimerMotionStyle(rawValue: motionStyleRaw) ?? .spring }
```
with:
```swift
    @AppStorage(TimerMotionStyle.storageKey) private var motionStyleRaw = TimerMotionStyle.heroMorph.rawValue
    private var motionStyle: TimerMotionStyle { TimerMotionStyle(rawValue: motionStyleRaw) ?? .heroMorph }
```

- [ ] **Step 2: Commit** (build happens in Task 3 after all edits, since these files compile together):
```bash
git add App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "feat(timer): default the start-timer motion to Hero Morph"
```

## Task 2: Delete the DEBUG motion picker + its @AppStorage in SettingsView

**Files:** Modify `App/Sources/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Remove the DEBUG @AppStorage** (lines 13-15):
```swift
    #if DEBUG
    @AppStorage(TimerMotionStyle.storageKey) private var timerMotionRaw = TimerMotionStyle.spring.rawValue
    #endif
```

- [ ] **Step 2: Remove the entire DEBUG "Timer motion" Section** (lines 118-137 — its own `#if DEBUG … #endif`, between the "Reminders" Section and the `--debug-scheduler` Section). Delete:
```swift
                #if DEBUG
                Section {
                    Picker(selection: $timerMotionRaw) {
                        ForEach(TimerMotionStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    } label: {
                        Label("Start-timer motion", systemImage: "wand.and.stars")
                    }
                    if let style = TimerMotionStyle(rawValue: timerMotionRaw) {
                        Text(style.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Timer motion")
                } footer: {
                    Text("Flip the Start ↔ Running animation, then open a project and tap Start to compare. DEBUG builds only.")
                }
                #endif
```
(Leave the separate `if CommandLine.arguments.contains("--debug-scheduler")` Section and its inner `#if DEBUG` ActivationMetrics link untouched.)

- [ ] **Step 3: Commit:**
```bash
git add App/Sources/Features/Settings/SettingsView.swift
git commit -m "chore(settings): remove the DEBUG start-timer motion picker"
```

## Task 3: Drop the orphaned picker-only members from TimerMotionStyle + build

**Files:** Modify `App/Sources/Features/Timer/RunningTimerCard.swift:366-396`

After Task 2, `TimerMotionStyle.label`, `.blurb`, `allCases` (CaseIterable) and `id` (Identifiable) have **zero references** (verified: their only users were the deleted picker; other `.label`/`.allCases` hits in the app are different enums). Remove them; keep the 3 cases + `storageKey` + `animation()`/`transition()` (the abstraction `ProjectDetailView` consumes).

- [ ] **Step 1: Replace the enum doc comment + header through the end of `blurb`** (lines 366-396):
```swift
/// User-selectable motion for the Start ↔ Running-card swap on the project-detail
/// screen, surfaced via a DEBUG-only picker in Settings so the feel can be chosen
/// live. All three are render-transform (opacity + scale/offset) transitions —
/// none clip or frame-constrain the card, so none can "squish" its content the
/// way the earlier height-animated expand did.
enum TimerMotionStyle: String, CaseIterable, Identifiable {
    /// Proposed default — grows into place with a soft overshoot.
    case spring
    /// Calm native cross-fade.
    case fadeScale
    /// Most drama — blooms open from the button's top edge.
    case heroMorph

    static let storageKey = "timerMotionStyle"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .spring: return "Spring Pop"
        case .fadeScale: return "Fade + Scale"
        case .heroMorph: return "Hero Morph"
        }
    }

    var blurb: String {
        switch self {
        case .spring: return "Grows into place with a soft overshoot."
        case .fadeScale: return "Quiet cross-fade — the native default."
        case .heroMorph: return "Blooms open from the button's edge."
        }
    }

    func animation(reduceMotion: Bool) -> Animation {
```
with:
```swift
/// Motion for the Start ↔ Running-card swap on the project-detail screen.
/// `heroMorph` is the shipped default (set via the `@AppStorage` default +
/// decode fallback in `ProjectDetailView`). `spring`/`fadeScale` are retained
/// so a legacy persisted key still resolves; all three are render-transform
/// (opacity + scale/offset) transitions that never clip or frame-constrain the
/// card. (A former DEBUG-only Settings picker chose between them — now removed.)
enum TimerMotionStyle: String {
    case spring
    case fadeScale
    case heroMorph

    static let storageKey = "timerMotionStyle"

    func animation(reduceMotion: Bool) -> Animation {
```

- [ ] **Step 2: Build the app** (run `xcodegen` first), expect `** BUILD SUCCEEDED **` — confirms no dangling `timerMotionRaw`/`label`/`blurb`/`allCases` references:
```bash
xcodegen generate --spec "$WT/project.yml" --project "$WT" && xcodebuild -project "$WT/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```
(`$WT` = `/Users/lbazerbashi/Elden Studios/billable/.worktrees/start-timer-motion`.)

- [ ] **Step 3: Verify no orphans:**
```bash
grep -rn "timerMotionRaw" "$WT/App/Sources"                       # expect: nothing
grep -rn "\.blurb\|TimerMotionStyle.allCases\|style\.label" "$WT/App/Sources"   # expect: no TimerMotionStyle hits
```

- [ ] **Step 4: Commit:**
```bash
git add App/Sources/Features/Timer/RunningTimerCard.swift
git commit -m "refactor(timer): drop picker-only TimerMotionStyle members after picker removal"
```

## Task 4: Final clean build + manual default check
- [ ] **Step 1:** Clean build → `** BUILD SUCCEEDED **`, 0 warnings: `xcodebuild … clean build`.
- [ ] **Step 2 (manual, Simulator, fresh install / no persisted key):** open a project → tap **Start** → confirm the Start ↔ Running swap uses **Hero Morph** (the ~0.5s bloom-from-the-button's-top with overshoot), not Spring Pop. Confirm **Settings has no "Timer motion" row**.

## Testing notes
- **No unit tests:** `TimerMotionStyle` + the `@AppStorage` defaults are App-target (not BillableCore), and the change is config + UI deletion. Verified by a clean build + grep (no orphaned refs) + the manual default check.
- **Migration:** production users never wrote the `timerMotionStyle` key → they get `.heroMorph`. Internal/DEBUG testers with a persisted `spring`/`fadeScale` key keep that motion (the case still resolves); reset the key to move them onto the default.
