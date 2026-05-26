# TestFlight Upload — Pickup Checklist

> **Status as of end of session 26 May 2026:**
> Code is shipped (v1.3 tag, MARKETING_VERSION 1.3.0, commit `b7b7e42` on main).
> Apple Distribution cert created tonight. Team ID confirmed: **`Y9AB4534BR`** (Elden Studios Company — NOT R38G6AYNFP, which is the personal team).
> Archive currently fails because the App ID at developer.apple.com is missing iCloud + App Groups capabilities.

---

## Pickup tomorrow — 3 browser steps, ~10-15 min total

### Step 1 — Enable capabilities on App ID `com.eldenstudios.billable`

1. Open https://developer.apple.com/account/resources/identifiers/list
2. Click **com.eldenstudios.billable**
3. In the Capabilities list, enable:
   - **iCloud** → Configure → check **CloudKit** → add container `iCloud.com.eldenstudios.billable`
   - **App Groups** → Configure → add group `group.com.eldenstudios.billable`
   - **Push Notifications** → verify checkbox is on
4. Click **Save** (top right of the page)

### Step 2 — Enable App Groups on widgets App ID

1. Same page → back to Identifiers list
2. Click **com.eldenstudios.billable.widgets**
3. Enable **App Groups** → use the SAME group `group.com.eldenstudios.billable`
4. Save

### Step 3 — Create App Store Connect app record

1. Open https://appstoreconnect.apple.com/apps
2. Click **+** → **New App**
3. Fill in:
   - Platforms: **iOS**
   - Name: `Cadence: Time Tracker`
   - Primary Language: **English (U.S.)**
   - Bundle ID: select **com.eldenstudios.billable** from dropdown
   - SKU: `cadence-ios-1`
   - User Access: **Full Access**
4. Click **Create**

---

## Then ping Claude

Paste this prompt to resume:

```
Done with the 3 browser setup steps. Pick up the TestFlight upload —
re-run the archive command, export, and walk me through uploading via
Xcode Organizer.
```

Claude will then:
1. Run `xcodebuild archive` with team `Y9AB4534BR` (auto-creates the distribution profile now that capabilities match)
2. Export to .ipa with method=app-store using `build/ExportOptions.plist` (already prepped)
3. Tell you to open Xcode → Window → Organizer → select the archive → Distribute App → App Store Connect → Upload
4. ~5-10 min upload + ~10-30 min Apple processing → build appears in TestFlight

---

## What's deferred (NOT blocking TestFlight, but blocks IAP sales)

- **Tax / Banking / Paid Apps Agreement** in App Store Connect → Business → Agreements/Tax/Banking
  - Required before subscriptions can actually sell to users
  - You can do this in parallel with the TestFlight upload — even while build processing

## What's done already (for reference)

| Done | What |
|---|---|
| ✅ | v1.3 tag pushed |
| ✅ | MARKETING_VERSION = 1.3.0 |
| ✅ | 9 App Store screenshots captured (1320×2868, iPhone 6.9") |
| ✅ | App Store metadata drafted (name/subtitle/keywords/description) |
| ✅ | Terms of Use + Privacy Policy live on GitHub Pages |
| ✅ | Repo public (`elden-studios/cadence`) |
| ✅ | Apple Development cert |
| ✅ | Apple Distribution cert (created tonight) |
| ✅ | Xcode signed in with Apple ID, Elden Studios Company team selected |
| ✅ | Marketing data seeder + paywall mock-prices flag (for future re-shoots) |
| ✅ | ExportOptions.plist prepped at `build/ExportOptions.plist` |
