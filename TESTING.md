# Testing

## BillableCore (core domain + business logic)

```sh
cd Packages/BillableCore && swift test
```

This is the canonical command. The full unit test suite (64 tests as of v1.1 Phase 1) lives in `Packages/BillableCore/Tests/BillableCoreTests/` and runs via SwiftPM directly, with no Xcode dependency.

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

## Why `xcodebuild ... test` doesn't run BillableCore tests

The `Billable` Xcode scheme's Test action only lists the `Billable` app target, which currently has no XCTest bundle attached. The auto-generated `BillableCore` scheme isn't configured for the test action either — `BillableCore` is a SwiftPM package dependency, and Xcode does not surface its tests through the host project's `xcodebuild test` flow by default.

This is an Xcode/SwiftPM tooling limitation, not a project bug. Use `swift test` for the unit suite. A proper iOS UI test target (`BillableUITests`) will be introduced in v1.1 Phase 6 (Task 6.4), at which point `xcodebuild ... test` against the `Billable` scheme will work for the UI smoke test.

## Local-only StoreKit testing

For sandbox IAP testing in the simulator, launch the app via Xcode's Run button (Cmd+R) — the scheme is configured with `storeKitConfiguration: App/Resources/Billable.storekit`, and Xcode injects the local test environment automatically. Launching via `xcrun simctl launch` will NOT pick up the StoreKit config (verified during v1 IAP work).
