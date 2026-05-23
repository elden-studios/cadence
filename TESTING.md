# Testing

## BillableCore (core domain + business logic)

```sh
cd Packages/BillableCore && swift test
```

This is the canonical command. The full unit test suite (121 tests as of v1.1.1) lives in `Packages/BillableCore/Tests/BillableCoreTests/` and runs via SwiftPM directly, with no Xcode dependency. Tests run in parallel by default; if you ever see a SIGTRAP crash, it usually means a test discarded its `ModelContainer` via a wildcard tuple binding — bind the container to a real name and add `_ = container` to keep it alive.

To filter to one suite:

```sh
cd Packages/BillableCore && swift test --filter Scheduling
```

## App build (without tests)

```sh
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

## Local-only StoreKit testing

For sandbox IAP testing in the simulator, launch the app via Xcode's Run button (Cmd+R) — the scheme is configured with `storeKitConfiguration: App/Resources/Billable.storekit`, and Xcode injects the local test environment automatically. Launching via `xcrun simctl launch` will NOT pick up the StoreKit config (verified during v1 IAP work).

## CloudKit reinstall smoke test (manual)

The CloudKit Mirror layer can't be exercised cleanly in unit tests (it requires a real iCloud container + entitlements). Before any TestFlight rollout that involves changes to mirrored SwiftData models, run this manual check:

**Setup (do once, on a real device tied to an iCloud account):**

1. Install a build from Xcode (Cmd+R) onto a physical device — the simulator's CloudKit support is incomplete.
2. Sign into iCloud on that device (System Settings → Apple ID → iCloud).
3. Open Cadence, complete onboarding, and create some data: a client with a recurring schedule, a couple of time entries, and one invoice in Sent status. Wait ~30 seconds for CloudKit to ingest.

**The test:**

1. **Delete the app** from the device (long-press → Remove App → Delete App).
2. **Reinstall** the build via Xcode (Cmd+R).
3. **Launch.** The app should NOT route through onboarding — it should land directly on the Today screen with the existing data restored from CloudKit. Expect a few seconds of "Reports tab → no data yet" while sync completes.

**Pass criteria:**

- The original client, projects, time entries, invoices, recurring templates, and reminder schedules all reappear within ~60 seconds.
- The local-only `ScheduledNotification` table starts empty (correct — local state was wiped) and re-populates via `Scheduler.resyncOnLaunch()` on the first scenePhase=`.active`.
- No "duplicate invoice" rows, no orphan templates, no crashes.

**Fail signals to watch for:**

- The recurrence "Next: …" date displays as `1 Jan 1970` (means `nextFireDate` didn't round-trip — likely a CloudKit migration bug).
- App crashes on first launch (means a new mirrored model failed CloudKit schema validation — check the device console).
- Reminder schedules show empty `fireDates` even though the source invoice is still Sent (means the InvoiceReminderSchedule → Invoice relationship didn't restore correctly).

This procedure should run before each TestFlight release that touches the `mirroredTypes` schema array in `BillableModelContainer`.

## CI / xcodebuild

`xcodebuild ... test` does not run BillableCore tests via the Billable scheme — the Billable target has no XCTest bundle attached, and the auto-generated BillableCore scheme isn't surfaced. This is an Xcode/SwiftPM tooling limitation. The Phase 6 `BillableUITests` target IS attached to the Billable scheme's test action, so:

```sh
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests test
```

…runs the UI smoke test. For full unit + UI coverage, the canonical sequence is:

```sh
cd Packages/BillableCore && swift test && cd ../..
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests test
```
