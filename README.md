# Billable

Native iOS time tracker + invoicing for solo creative freelancers and consultants. One job: turn tracked time into a paid invoice, entirely on the phone.

## Repository layout

```
Billable/
├── App/                       # iOS app target (SwiftUI)
├── Watch/                     # watchOS companion target
├── Widgets/                   # Widget extension (home/lock-screen + ActivityKit Live Activity)
└── Packages/
    └── BillableCore/          # Shared Swift Package: models, business logic, PDF, App Intents
```

`BillableCore` holds all domain logic and is consumed by every target. The Xcode project (added later) wires everything together.

## Tech stack

- iOS 17+, watchOS 10+
- Swift 6, strict concurrency
- SwiftUI + `@Observable`
- SwiftData with CloudKit Mirror (private database) — no server, your data lives in your iCloud
- StoreKit 2, ActivityKit, WidgetKit, App Intents
- PDFKit + SwiftUI `ImageRenderer` for invoice PDFs
- Swift Testing + swift-snapshot-testing

## Build plan

See `../../.claude/plans/build-brief-billable-nested-swan.md` for the v1 design + build order.

## Status

In active build. Step 1 (foundation) underway.
