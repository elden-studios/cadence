# Code Review Style Guide — Billable (Cadence)

Review thoroughly and line-by-line. Flag every issue you find, including low-severity
ones (naming, clarity, dead code). Prefer concrete, compilable suggestions over vague
advice. If you cannot verify a suggestion compiles on this toolchain, say so instead of
asserting it.

## Toolchain (do not suggest code that breaks these)

- Target: **iOS 26.5 / Xcode 26**, Swift 6 strict concurrency.
- This is a real, building app. Suggestions must compile on the iOS 26.5 SDK.

### Known SDK constraints — do NOT re-flag these

- **UIKit delegate Coordinators are not `@MainActor`.** Protocols like
  `MFMailComposeViewControllerDelegate` are *not* `@MainActor`-annotated on the iOS 26.5
  SDK. Do not suggest annotating a `UIViewControllerRepresentable.Coordinator` with
  `@MainActor` — a `@MainActor` Coordinator cannot satisfy the protocol's `nonisolated`
  requirements. The `DispatchQueue.main.async` + `MainActor.assumeIsolated` bridge is
  required, not optional.
- **SwiftUI `.task { }` closures are non-throwing** (`() async -> Void`). Do not suggest
  `try await Task.sleep(...)` inside `.task { }` without `try?` — it will not compile.

## What to prioritize

- **Performance in SwiftUI bodies.** Flag O(N×M) recomputation, work that should be
  hoisted out of the view body, and SwiftData N+1 fetches. Prefer
  `relationshipKeyPathsForPrefetching` on a `FetchDescriptor` over per-row faulting and
  over ad-hoc `@State` caches.
- **Date / calendar correctness.** Calendar-day math must use `Calendar.startOfDay(for:)`,
  not raw 24-hour `dateComponents([.day], from:to:)` differences. Call out anywhere a
  "days ago" / relative-date calculation could be off by a day across timezones or DST.
- **Concurrency correctness** under Swift 6 strict checking: actor isolation, `Sendable`,
  data races, unstructured `Task` lifetime.
- **Optionals and force-unwraps**, error handling, and edge cases (empty collections,
  first-run / empty-state, large datasets).
- **Test coverage gaps** for any behavior change, especially date/timezone logic — prefer
  a fixed-timezone `Calendar` in tests, not clean 24-hour offsets.

## Out of scope

- Don't comment on generated files (`*.pbxproj`, the `.xcodeproj`, asset catalogs, `build/`).
- Don't suggest broad refactors unrelated to the diff unless they're a genuine correctness
  or performance risk.
