import SwiftUI
import SwiftData
import StoreKit
import BillableCore

/// The contextual paywall sheet. Shown when a free user tries to use a Pro
/// feature (Create Invoice, add 3rd client, Reports, exports, or Settings →
/// Upgrade). Designed for one job: communicate value, accept the purchase, and
/// get out of the way fast.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    /// What action the user was trying to take when the paywall fired —
    /// shapes the headline so the value prop matches the context.
    enum Trigger: Equatable {
        case reports
        case settings
        case removeWatermark  // NEW

        var headline: String {
            switch self {
            case .reports:         "Know what you've earned — and what you're owed."
            case .settings:        "Go Pro."
            case .removeWatermark: "Remove the watermark."
            }
        }
        var subhead: String {
            switch self {
            case .reports:         "Full Reports dashboard, watermark-free invoices, and CSV export — all in one upgrade."
            case .settings:        "Watermark-free invoices, full Reports, CSV exports."
            case .removeWatermark: "Pro removes 'Sent with Cadence' from your invoice PDFs and unlocks Reports + CSV export."
            }
        }
        /// Stable, snake_cased trigger id stamped into every funnel metric so a
        /// future price/layout test slices cleanly by entry point.
        var metricKey: String {
            switch self {
            case .reports:         "reports"
            case .settings:        "settings"
            case .removeWatermark: "remove_watermark"
            }
        }
    }

    let trigger: Trigger
    /// When rendered embedded in a tab (the locked Reports tab) rather than
    /// presented as a sheet, there is nothing to dismiss — hide the toolbar
    /// close button so it isn't a dead control.
    var isEmbedded: Bool = false
    @State private var manager = SubscriptionManager.shared
    @State private var selection: Plan = .yearly
    @State private var isProcessing = false
    @State private var error: String?
    @State private var teaserModel: ReportsTeaserModel?
    /// Records the Reports paywall impression only once per presentation/mount —
    /// the embedded tab stays mounted, so .onAppear re-fires on revisits. (S4-5)
    @State private var didRecordImpression = false
    /// One-shot guard so the owned-Lifetime funnel event records exactly once per
    /// presentation even though `ownsLifetime` resolves async after onAppear. (NEW-S1-2)
    @State private var didRecordLifetimeOwned = false
    @State private var restoreNotice: String?

    // Backing data for the `.reports` crisp-taste header. We compute a live
    // snapshot from the user's own entries/invoices so the teaser shows *their*
    // numbers; if they have nothing reportable yet, we fall back to
    // `ReportsSampleData` so the pitch never renders empty zeros.
    @Query private var reportEntries: [TimeEntry]
    @Query private var reportInvoices: [Invoice]
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    enum Plan: String, CaseIterable { case yearly, monthly, lifetime }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headerSection
                    valueBullets
                    // When the user already owns Lifetime, the tier picker + CTA
                    // collapse to the owned label (the double-buy guard); only
                    // the affordance block renders.
                    if !manager.ownsLifetime {
                        VStack(alignment: .leading, spacing: 12) {
                            pricePicker
                            purchaseButton
                            trialTerms
                        }
                    }
                    lifetimeAffordance
                    if manager.ownsLifetime {
                        termsPrivacyLinks
                    } else {
                        secondaryActions
                        finePrint
                    }
                }
                .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close paywall")
                            .disabled(isProcessing)
                    }
                }
            }
            .task { manager.start() }
            .onAppear {
                // Privacy-pure, on-device impression count for the Reports
                // paywall (UserDefaults; never transmitted). See spec §5.
                if trigger == .reports && !didRecordImpression {
                    ReportsConversionMetrics.recordImpression()
                    didRecordImpression = true
                }
                // On-device funnel: every paywall impression, plus a distinct
                // counter when an owning user re-opens it (so the owned-state
                // view rate is sliceable from genuine sale opportunities).
                PaywallMetrics.record(.paywallView, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey)
                if manager.ownsLifetime {
                    PaywallMetrics.record(.lifetimeOwnedView, variant: PricingConfig.variant,
                                          trigger: trigger.metricKey, tier: "lifetime")
                    didRecordLifetimeOwned = true
                }
                recomputeTeaser()
            }
            .onChange(of: reportEntries) { recomputeTeaser() }
            .onChange(of: reportInvoices) { recomputeTeaser() }
            .onChange(of: manager.ownsLifetime) { _, owned in
                guard owned, !didRecordLifetimeOwned else { return }
                didRecordLifetimeOwned = true
                PaywallMetrics.record(.lifetimeOwnedView, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey, tier: "lifetime")
            }
            .alert("Couldn't complete purchase", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
            .alert("Restore purchases", isPresented: Binding(
                get: { restoreNotice != nil }, set: { if !$0 { restoreNotice = nil } }
            )) {
                Button("OK", role: .cancel) { restoreNotice = nil }
            } message: {
                Text(restoreNotice ?? "")
            }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        if trigger == .reports {
            crispTasteHeader
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(trigger.headline)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(trigger.subhead)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reports crisp-taste header

    /// A real slice of the Layout-A Reports dashboard shown above the shared Pro
    /// core when the paywall is entered from Reports: the "as of today" AR card +
    /// an Invoiced/Collected/Rate tile row. Fed from the user's own data when they
    /// have something reportable, else from `ReportsSampleData`. Decorative — the
    /// real headline sits above it; the figures themselves are `accessibilityHidden`.
    private var crispTasteHeader: some View {
        // Don't run the O(N) ReportsAggregator.snapshot in `body`: on the first
        // frame (before .onAppear memoizes the real model) use an O(1) sample
        // placeholder, redacted so no figures flash before the real numbers land.
        let isPlaceholder = (teaserModel == nil)
        let model = teaserModel ?? sampleTeaserModel()

        return VStack(alignment: .leading, spacing: 14) {
            Text(trigger.headline)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            VStack(alignment: .leading, spacing: 10) {
                teaserARCard(model)
                teaserTileRow(model)
                if model.isSample && !isPlaceholder {
                    Text("Sample preview")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .redacted(reason: isPlaceholder ? .placeholder : [])
            .accessibilityHidden(true)

            Text(trigger.subhead)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    /// Display-only figures for the teaser, plus whether they're sample data.
    private struct ReportsTeaserModel {
        let currencyCode: String
        let outstanding: Decimal
        let overdue: Decimal
        let overdueCount: Int
        let avgDaysToPay: Int?
        let invoiced: Decimal
        let collected: Decimal
        let effectiveRate: Decimal?
        let isSample: Bool
    }

    /// Memoize the teaser so the O(N) `ReportsAggregator.snapshot` isn't recomputed
    /// on every body evaluation (mirrors ReportsView's memoization). Only `.reports`
    /// renders the teaser, so other triggers skip the work.
    private func recomputeTeaser() {
        guard trigger == .reports else { return }
        teaserModel = makeTeaserModel()
    }

    /// O(1) placeholder for the first frame, before `recomputeTeaser()` memoizes the
    /// real snapshot. Pure static sample — never touches @Query data, so it costs
    /// nothing in `body`; real numbers replace it on `.onAppear`.
    private func sampleTeaserModel() -> ReportsTeaserModel {
        ReportsTeaserModel(
            currencyCode: profiles.first?.currencyCode ?? "USD",
            outstanding: ReportsSampleData.outstanding,
            overdue: ReportsSampleData.overdue,
            overdueCount: ReportsSampleData.overdueCount,
            avgDaysToPay: ReportsSampleData.avgDaysToPay,
            invoiced: ReportsSampleData.invoiced,
            collected: ReportsSampleData.collected,
            effectiveRate: ReportsSampleData.effectiveRate,
            isSample: true
        )
    }

    /// Compute the teaser from the user's real snapshot when they have reportable
    /// data; otherwise use the representative sample slice.
    private func makeTeaserModel() -> ReportsTeaserModel {
        let code = profiles.first?.currencyCode ?? "USD"
        let snap = ReportsAggregator.snapshot(
            entries: reportEntries,
            invoices: reportInvoices,
            in: .thisMonth,
            activeCurrency: code
        )
        if snap.hasReportableData {
            return ReportsTeaserModel(
                currencyCode: code,
                outstanding: snap.ar.outstanding,
                overdue: snap.ar.overdue,
                overdueCount: snap.ar.overdueCount,
                avgDaysToPay: snap.ar.avgDaysToPay.map { Int($0.rounded()) },
                invoiced: snap.money.invoiced,
                collected: snap.money.collected,
                effectiveRate: snap.performance.effectiveRate,
                isSample: false
            )
        } else {
            return ReportsTeaserModel(
                currencyCode: code,
                outstanding: ReportsSampleData.outstanding,
                overdue: ReportsSampleData.overdue,
                overdueCount: ReportsSampleData.overdueCount,
                avgDaysToPay: ReportsSampleData.avgDaysToPay,
                invoiced: ReportsSampleData.invoiced,
                collected: ReportsSampleData.collected,
                effectiveRate: ReportsSampleData.effectiveRate,
                isSample: true
            )
        }
    }

    private func teaserARCard(_ model: ReportsTeaserModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GET PAID")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("as of today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(currency(model.outstanding, code: model.currencyCode))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            if model.overdue > 0 {
                Text("\(currency(model.overdue, code: model.currencyCode)) overdue · \(model.overdueCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red, in: Capsule())
            }
            if let days = model.avgDaysToPay {
                Label("~\(days) days to pay", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    private func teaserTileRow(_ model: ReportsTeaserModel) -> some View {
        HStack(spacing: 12) {
            teaserTile("INVOICED", currency(model.invoiced, code: model.currencyCode), .blue)
            teaserTile("COLLECTED", currency(model.collected, code: model.currencyCode), .green)
            teaserTile("RATE",
                       model.effectiveRate.map { "\(currency($0, code: model.currencyCode))/h" } ?? "—",
                       .primary)
        }
    }

    private func teaserTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }

    private func currency(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code))
    }

    /// The shared "Everything in Pro" core — identical for every trigger,
    /// including `.reports`. Subscribing from any doorway visibly unlocks all of
    /// Pro, not just the contextual feature.
    private var valueBullets: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("doc.text", "Clean, professional invoices",
                   "Send polished invoices without 'Sent with Cadence' in the footer.")
            bullet("chart.bar", "Full Reports & insights",
                   "Invoiced, collected, what you're owed — plus hours by client and project.")
            bullet("square.and.arrow.up", "CSV export",
                   "Clean exports for your accountant.")
        }
    }

    private func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pricePicker: some View {
        if mockPaywallPrices {
            // App Store marketing screenshots: render a fully-loaded paywall
            // with prices from Billable.storekit baked in. Triggered only by
            // the `--mock-paywall-prices` launch arg; never active in prod.
            VStack(spacing: 10) {
                mockPlanRow(.yearly,  price: "$39.99", perCycle: "Just $3.33 per month, billed yearly")
                mockPlanRow(.monthly, price: "$3.99",  perCycle: "Billed monthly · Cancel anytime")
            }
        } else {
        switch manager.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 100)
        case .ready:
            VStack(spacing: 10) {
                planRow(.yearly)
                planRow(.monthly)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await manager.reloadProducts() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        }
    }

    /// Returns true when the app was launched with `--mock-paywall-prices`
    /// (used to render a populated paywall for App Store screenshots when no
    /// StoreKit Testing session is attached).
    private var mockPaywallPrices: Bool {
        CommandLine.arguments.contains("--mock-paywall-prices")
    }

    /// Visual twin of `planRow` that takes raw display strings instead of a
    /// StoreKit `Product`. Used only when `--mock-paywall-prices` is set. Mirrors
    /// the hero/recede styling so marketing screenshots match the real layout.
    @ViewBuilder
    private func mockPlanRow(_ plan: Plan, price: String, perCycle: String) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        Button {
            selection = plan
            PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: plan.rawValue)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(isHero ? "Yearly" : "Monthly")
                            .font(.headline)
                        if isHero {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                            // Live products are absent in mock mode, so the
                            // computed `savingsPill` would be empty — use a
                            // static figure ($47.88 − $39.99) for screenshots.
                            Text("SAVE $7.89 · about 2 months free")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.18), in: .capsule)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(perCycle)
                        .font(.caption)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
                }
                Spacer()
                Text(price)
                    .font(.title3.weight(.semibold).monospacedDigit())
                if isHero && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .padding(.vertical, isHero ? 20 : 14)
            .padding(.horizontal, 14)
            .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHero {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func planRow(_ plan: Plan) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        let product: Product? = isHero ? manager.yearly : manager.monthly

        Button {
            selection = plan
            PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: plan.rawValue)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(isHero ? "Yearly" : "Monthly")
                            .font(.headline)
                        if isHero {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                            savingsPill
                        }
                    }
                    Text(perCycleLabel(for: plan, product: product))
                        .font(.caption)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
                }
                Spacer()
                if let product {
                    Text(product.displayPrice)
                        .font(.title3.weight(.semibold).monospacedDigit())
                } else {
                    ProgressView().controlSize(.small)
                        .tint(isHero ? .white : nil)
                }
                if isHero && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            // The hero gets taller padding + a solid accent fill + white text so
            // Yearly is the unmistakable default; Monthly recedes to a plain card.
            .padding(.vertical, isHero ? 20 : 14)
            .padding(.horizontal, 14)
            .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHero {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Computed savings badge on the yearly tier — the real saving vs. 12× monthly,
    /// led by the tangible "$X · about N months free" framing (never a stale string).
    /// Hidden until both products load so it can't flash an incorrect figure.
    @ViewBuilder
    private var savingsPill: some View {
        let monthlyCurrency = manager.monthly?.priceFormatStyle.locale.currency?.identifier
        let yearlyCurrency  = manager.yearly?.priceFormatStyle.locale.currency?.identifier
        if let monthlyCurrency, let yearlyCurrency, monthlyCurrency == yearlyCurrency,
           let m = manager.monthly?.price, let y = manager.yearly?.price,
           let s = PricingDisplay.annualSavings(monthlyPrice: m, yearlyPrice: y) {
            Text(PricingDisplay.savingsBadge(s, currencyCode: yearlyCurrency))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green.opacity(0.18), in: .capsule)
                .foregroundStyle(.green)
        }
    }

    /// ISO currency code for badge/copy money. `Decimal.FormatStyle.Currency`
    /// doesn't expose its code on this SDK, so derive it from the product's own
    /// locale, falling back to the device currency then USD.
    private var yearlyCurrencyCode: String {
        manager.yearly?.priceFormatStyle.locale.currency?.identifier
            ?? Locale.current.currency?.identifier
            ?? "USD"
    }

    private func perCycleLabel(for plan: Plan, product: Product?) -> String {
        switch plan {
        case .yearly:
            guard let yearly = product else { return "Billed yearly" }
            let monthly = yearly.price / 12
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = yearly.priceFormatStyle.locale
            let perMonth = formatter.string(from: monthly as NSDecimalNumber) ?? ""
            return "Just \(perMonth) per month, billed yearly"
        case .monthly:
            return "Billed monthly · Cancel anytime"
        case .lifetime:
            // Lifetime isn't shown in the tier picker (it lives in the demoted
            // affordance), so this is defensive — keep the switch exhaustive.
            return "One-time purchase"
        }
    }

    private var purchaseButton: some View {
        Button {
            Task { await runPurchase() }
        } label: {
            HStack {
                if isProcessing {
                    ProgressView().tint(.white)
                }
                Text(purchaseButtonTitle)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled((selectedProduct == nil && !mockPaywallPrices) || isProcessing)
    }

    private var purchaseButtonTitle: String {
        // Lifetime is a one-time buy — never a trial; name the price on the CTA.
        if selection == .lifetime {
            return "Buy Lifetime — \(manager.lifetime?.displayPrice ?? "$99.99")"
        }
        // In marketing-screenshot mode, surface the strongest CTA — the free
        // trial — since the SubscriptionManager has no real products to derive
        // eligibility from.
        if mockPaywallPrices { return "Start 7-day free trial" }
        return manager.eligibleForIntroOffer ? "Start 7-day free trial" : "Subscribe"
    }

    /// Trial-/terms copy under the CTA. Lifetime is a one-time buy, so it shows
    /// nothing here. For subscriptions the trial reassurance is promoted out of
    /// fine print into a prominent `.footnote` immediately under the CTA (the
    /// strongest objection-killer), with the price/auto-renew note beneath. The
    /// price + billing cycle track the CURRENTLY-SELECTED plan (so selecting
    /// Monthly reads "$3.99/month", not the yearly price).
    @ViewBuilder
    private var trialTerms: some View {
        if selection != .lifetime {
            let price = selectedPlanPrice
            let cycle = selection == .yearly ? "year" : "month"
            let showsTrial = mockPaywallPrices || manager.eligibleForIntroOffer
            VStack(spacing: 6) {
                if showsTrial {
                    Text(PricingConfig.trialReassurance)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Text("7 days free, then \(price)/\(cycle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(price)/\(cycle) · Cancel anytime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
        }
    }

    /// Display price for the currently-selected plan, with the list-price
    /// fallback used in marketing-screenshot mode (no live products).
    private var selectedPlanPrice: String {
        switch selection {
        case .yearly:   return (mockPaywallPrices ? nil : manager.yearly?.displayPrice) ?? "$39.99"
        case .monthly:  return (mockPaywallPrices ? nil : manager.monthly?.displayPrice) ?? "$3.99"
        case .lifetime: return manager.lifetime?.displayPrice ?? "$99.99"
        }
    }

    /// Demoted "or pay once" lifetime option — rendered BELOW the trial-led CTA,
    /// not as a co-equal third tier. When the user already owns Lifetime it
    /// collapses to the owned-state label (the rest of the purchase UI is hidden
    /// by the body's `!ownsLifetime` guard), which doubles as the double-buy guard.
    /// Display price for the Lifetime tier, or nil when it shouldn't be offered.
    /// Real path: the loaded StoreKit product's localized price. Mock path
    /// (`--mock-paywall-prices`, no live products): a static list price so the
    /// affordance + CTA render in marketing screenshots / demos. nil ⇒ hide it.
    private var lifetimeDisplayPrice: String? {
        if let lifetime = manager.lifetime { return lifetime.displayPrice }
        return mockPaywallPrices ? "$99.99" : nil
    }

    @ViewBuilder
    private var lifetimeAffordance: some View {
        if manager.ownsLifetime {
            Label(PricingConfig.ownedTitle, systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else if let price = lifetimeDisplayPrice {
            Divider().padding(.vertical, 4)
            Button {
                selection = .lifetime
                PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey, tier: "lifetime")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PricingConfig.lifetimeAffordanceTitle).font(.subheadline.weight(.semibold))
                        Text("\(PricingConfig.lifetimeAffordanceSubtitle) — \(price)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .center) {
                if selection == .lifetime {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
    }

    /// Terms of Use + Privacy Policy links shown to Lifetime owners in place of
    /// the full `secondaryActions` row (they don't need a Restore button or the
    /// auto-renew fine print). (NEW-S1-4)
    private var termsPrivacyLinks: some View {
        HStack {
            Spacer()
            Link("Terms", destination: URL(string: "https://elden-studios.github.io/cadence/legal/terms")!)
                .font(.subheadline)
            Link("Privacy", destination: URL(string: "https://elden-studios.github.io/cadence/legal/privacy")!)
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }

    private var secondaryActions: some View {
        HStack {
            Button("Restore purchases") {
                PaywallMetrics.record(.restoreTapped, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey)
                Task { await restore() }
            }
            .font(.subheadline)
            Spacer()
            Link("Terms", destination: URL(string: "https://elden-studios.github.io/cadence/legal/terms")!)
                .font(.subheadline)
            Link("Privacy", destination: URL(string: "https://elden-studios.github.io/cadence/legal/privacy")!)
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }

    private var finePrint: some View {
        Text("Subscriptions auto-renew. You can cancel anytime in your App Store account settings.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
    }

    // MARK: - Behavior

    private var selectedProduct: Product? {
        switch selection {
        case .yearly:   manager.yearly
        case .monthly:  manager.monthly
        case .lifetime: manager.lifetime
        }
    }

    private func runPurchase() async {
        guard let product = selectedProduct else { return }
        // Snapshot the tier + trial-eligibility up front so the funnel stamp is
        // stable even if state changes during the await.
        let tier = selection
        let wasIntroEligibleSub = (tier != .lifetime) && manager.eligibleForIntroOffer
        isProcessing = true
        defer { isProcessing = false }
        PaywallMetrics.record(.purchaseStart, variant: PricingConfig.variant,
                              trigger: trigger.metricKey, tier: tier.rawValue)
        let outcome = await manager.purchase(product)
        switch outcome {
        case .success:
            PaywallMetrics.record(.purchaseSuccess, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: tier.rawValue)
            // A trial only begins for an intro-eligible subscription, never the
            // one-time Lifetime buy.
            if wasIntroEligibleSub {
                PaywallMetrics.record(.trialStart, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey, tier: tier.rawValue)
            }
            // Count a Reports-attributed conversion (on-device only). See spec §5.
            if trigger == .reports { ReportsConversionMetrics.recordConversion() }
            dismiss()
        case .pending, .userCancelled:
            break
        case .failed(let message):
            PaywallMetrics.record(.purchaseFailure, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: tier.rawValue)
            error = message
        }
    }

    private func restore() async {
        isProcessing = true
        defer { isProcessing = false }
        let restored = await manager.restore()
        if restored {
            dismiss()
        } else {
            restoreNotice = "No active purchases were found for your Apple ID."
        }
    }
}
