import SwiftUI
import SwiftData
import StoreKit
import Charts
import BillableCore

/// The contextual paywall sheet. Shown when a free user tries to use a Pro
/// feature (Create Invoice, add 3rd client, Reports, exports, or Settings →
/// Upgrade). Designed for one job: communicate value, accept the purchase, and
/// get out of the way fast.
struct PaywallView: View {
    /// Shared gold accent for the Lifetime "pay once" tier. Extracted so both
    /// `mockPlanRow` and `planRow` reference the same literal.
    private static let lifetimeGold = Color(red: 0.72, green: 0.53, blue: 0.04)

    @Environment(\.dismiss) private var dismiss

    /// What action the user was trying to take when the paywall fired —
    /// shapes the headline so the value prop matches the context.
    enum Trigger: Equatable {
        case reports
        case settings
        case removeWatermark  // NEW

        var headline: String {
            switch self {
            case .reports:         "Know what you're owed."
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
                .lineLimit(1)

            teaserChartHero(model)
                .redacted(reason: isPlaceholder ? .placeholder : [])
                .accessibilityHidden(true)

            if model.isSample && !isPlaceholder {
                Text("Sample preview")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
        /// Year-to-date collected (Σ paid invoice totals in the current calendar year).
        let collectedThisYear: Decimal
        let effectiveRate: Decimal?
        let isSample: Bool
        /// Six monthly "collected" buckets (oldest→newest) driving the teaser bar chart.
        let collectedSeries: [ReportsAggregator.TrendPoint]
    }

    /// Memoize the teaser so the O(N) `ReportsAggregator.snapshot` isn't recomputed
    /// on every body evaluation (mirrors ReportsView's memoization). Only `.reports`
    /// renders the teaser, so other triggers skip the work.
    private func recomputeTeaser() {
        guard trigger == .reports else { return }
        teaserModel = makeTeaserModel()
    }

    /// Builds a sample collected series mapped onto the real trailing-6 month starts ending now,
    /// so month labels are calendar-derived (never hardcoded) while amounts are the sample values.
    private func sampleCollectedSeries(asOf now: Date = .now, calendar: Calendar = .current) -> [ReportsAggregator.TrendPoint] {
        let values = ReportsSampleData.collectedLast6Months
        guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let count = values.count
        return values.enumerated().compactMap { idx, amount in
            // idx 0 == oldest (count-1 months ago) … idx count-1 == current month.
            guard let start = calendar.date(byAdding: .month, value: -(count - 1 - idx), to: thisMonthStart) else { return nil }
            return ReportsAggregator.TrendPoint(id: start, bucketStart: start, amount: amount)
        }
    }

    /// O(1) placeholder for the first frame, before `recomputeTeaser()` memoizes the
    /// real snapshot. Pure static sample — never touches @Query data, so it costs
    /// nothing in `body`; real numbers replace it on `.onAppear`.
    private func sampleTeaserModel() -> ReportsTeaserModel {
        // Use the sum of collectedLast6Months as the "This year" sample so the stat
        // cell is non-zero and coherent with the sample chart bars.
        let sampleCollectedYTD = ReportsSampleData.collectedLast6Months.reduce(Decimal(0), +)
        return ReportsTeaserModel(
            currencyCode: profiles.first?.currencyCode ?? "USD",
            outstanding: ReportsSampleData.outstanding,
            overdue: ReportsSampleData.overdue,
            overdueCount: ReportsSampleData.overdueCount,
            avgDaysToPay: ReportsSampleData.avgDaysToPay,
            invoiced: ReportsSampleData.invoiced,
            collectedThisYear: sampleCollectedYTD,
            effectiveRate: ReportsSampleData.effectiveRate,
            isSample: true,
            collectedSeries: sampleCollectedSeries()
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
        // Build the real monthly-collected trend — reads only Invoice scalars
        // (status/paidAt/total/currencyCodeSnapshot), never traverses \.project
        // or \.project?.client, so the CloudKit nested-keypath trap cannot occur.
        let realSeries = ReportsAggregator.collectedMonthlyTrend(
            invoices: reportInvoices,
            activeCurrency: code
        )
        let collectedHistoryOK = ReportsAggregator.hasEnoughCollectedHistory(realSeries)
        if snap.hasReportableData && collectedHistoryOK {
            // YTD collected: pure Invoice-scalar helper, no relationship traversal,
            // reuses the existing reportInvoices @Query — no new fetch.
            let ytd = ReportsAggregator.collectedThisYear(
                invoices: reportInvoices,
                activeCurrency: code
            )
            return ReportsTeaserModel(
                currencyCode: code,
                outstanding: snap.ar.outstanding,
                overdue: snap.ar.overdue,
                overdueCount: snap.ar.overdueCount,
                avgDaysToPay: snap.ar.avgDaysToPay.map { Int($0.rounded()) },
                invoiced: snap.money.invoiced,
                collectedThisYear: ytd,
                effectiveRate: snap.performance.effectiveRate,
                isSample: false,
                collectedSeries: realSeries
            )
        } else {
            let sampleCollectedYTD = ReportsSampleData.collectedLast6Months.reduce(Decimal(0), +)
            return ReportsTeaserModel(
                currencyCode: code,
                outstanding: ReportsSampleData.outstanding,
                overdue: ReportsSampleData.overdue,
                overdueCount: ReportsSampleData.overdueCount,
                avgDaysToPay: ReportsSampleData.avgDaysToPay,
                invoiced: ReportsSampleData.invoiced,
                collectedThisYear: sampleCollectedYTD,
                effectiveRate: ReportsSampleData.effectiveRate,
                isSample: true,
                collectedSeries: sampleCollectedSeries()
            )
        }
    }

    private func currency(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code))
    }

    // MARK: - Chart-led locked teaser (B2)

    /// Locked bar-chart hero shown in the Reports paywall teaser. Always wrapped in
    /// `.redacted` + `.accessibilityHidden(true)` by the caller (`crispTasteHeader`).
    @ViewBuilder
    private func teaserChartHero(_ model: ReportsTeaserModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Always-on locked-preview eyebrow (both real and sample states).
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                Text("Your Reports preview")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.tint)

            Text("Collected · last 6 months")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.collectedSeries) { point in
                BarMark(
                    x: .value("Month", point.bucketStart, unit: .month),
                    y: .value("Collected", (point.amount as NSDecimalNumber).doubleValue)
                )
                .foregroundStyle(Color.green.gradient)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)

            teaserStatLine(model)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func teaserStatLine(_ model: ReportsTeaserModel) -> some View {
        HStack(spacing: 16) {
            statCell("Owed", currency(model.outstanding, code: model.currencyCode))
            Divider().frame(height: 28)
            statCell("This year", currency(model.collectedThisYear, code: model.currencyCode))
            Divider().frame(height: 28)
            statCell("Effective rate", model.effectiveRate.map { "\(currency($0, code: model.currencyCode))/h" } ?? "—")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                mockPlanRow(.monthly,  price: "$3.99",  perCycle: "Billed monthly · Cancel anytime")
                mockPlanRow(.yearly,   price: "$39.99", perCycle: "Just $3.33/mo · 2 months free")
                mockPlanRow(.lifetime, price: "$99.99", perCycle: PricingConfig.lifetimePeerSubtitle)
            }
        } else {
        switch manager.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 100)
        case .ready:
            VStack(spacing: 10) {
                planRow(.monthly)
                planRow(.yearly)
                planRow(.lifetime)
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
    /// the three-tier hero/recede styling so marketing screenshots match the live layout.
    @ViewBuilder
    private func mockPlanRow(_ plan: Plan, price: String, perCycle: String) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        let isLifetime = (plan == .lifetime)
        let selectionAccent: Color = isLifetime ? Self.lifetimeGold : Color.accentColor
        Button {
            selection = plan
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(planTitle(plan))
                            .font(.headline)
                        if isHero {
                            Text(PricingConfig.bestValueBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                        } else if isLifetime {
                            Text(PricingConfig.payOnceBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Self.lifetimeGold.opacity(0.16), in: .capsule)
                                .foregroundStyle(Self.lifetimeGold)
                        }
                    }
                    Text(perCycle)
                        .font(.caption)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
                }
                Spacer()
                if isLifetime {
                    Text("\(price) \(PricingConfig.lifetimeOnceSuffix)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                } else {
                    Text(price)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(selectionAccent))
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
                    .strokeBorder(isSelected ? selectionAccent : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func planRow(_ plan: Plan) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        let isLifetime = (plan == .lifetime)
        let product: Product? = {
            switch plan {
            case .yearly:   return manager.yearly
            case .monthly:  return manager.monthly
            case .lifetime: return manager.lifetime
            }
        }()
        // Gold accent for the Lifetime "pay once" peer; blue accent hero for Yearly;
        // recessed card for Monthly. Lifetime's selected border/badge read gold.
        let selectionAccent: Color = isLifetime ? Self.lifetimeGold : Color.accentColor

        Button {
            selection = plan
            PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: plan.rawValue)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(planTitle(plan))
                            .font(.headline)
                        if isHero {
                            Text(PricingConfig.bestValueBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                        } else if isLifetime {
                            Text(PricingConfig.payOnceBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Self.lifetimeGold.opacity(0.16), in: .capsule)
                                .foregroundStyle(Self.lifetimeGold)
                        }
                    }
                    if let sub = planSubLine(plan, product: product) {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                    : AnyShapeStyle(.secondary))
                    }
                }
                Spacer()
                planPrice(plan, product: product, isHero: isHero)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(selectionAccent))
                }
            }
            // The hero gets taller padding + a solid accent fill + white text so
            // Yearly is the default; Monthly/Lifetime recede to plain cards with a
            // consistent selection border.
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
                    .strokeBorder(isSelected ? selectionAccent : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func planTitle(_ plan: Plan) -> String {
        switch plan {
        case .yearly:   return "Yearly"
        case .monthly:  return "Monthly"
        case .lifetime: return "Lifetime"
        }
    }

    /// Sub-line under each tier title. Yearly carries the per-locale
    /// "Just $X/mo · 2 months free" saving (hidden when products/currencies
    /// aren't comparable); Monthly + Lifetime carry their static framing.
    private func planSubLine(_ plan: Plan, product: Product?) -> String? {
        switch plan {
        case .yearly:
            // Fall back to "Billed yearly" when the yearly product isn't loaded yet,
            // keeping the sub-line visible rather than hiding it. When both products
            // are loaded, use the locale-aware per-month saving line; if currencies
            // mismatch (e.g. monthly loaded in a different locale), omit the months-free
            // clause and fall back to "Billed yearly" again via the nil-coalescing.
            guard let yearly = product else { return "Billed yearly" }
            let monthlyCurrency = manager.monthly?.priceFormatStyle.locale.currency?.identifier
            let yearlyCurrency  = yearly.priceFormatStyle.locale.currency?.identifier
            let comparableMonthly: Decimal? =
                (monthlyCurrency != nil && monthlyCurrency == yearlyCurrency) ? manager.monthly?.price : nil
            return PaywallCopy.monthlyEquivalentLine(
                yearlyPrice: yearly.price,
                monthlyPrice: comparableMonthly,
                locale: yearly.priceFormatStyle.locale)
                ?? "Billed yearly"
        case .monthly:
            return "Billed monthly · Cancel anytime"
        case .lifetime:
            return PricingConfig.lifetimePeerSubtitle
        }
    }

    /// The trailing price for a tier. Lifetime composes "<price> once"; others
    /// show the plain localized display price, or a spinner while loading.
    @ViewBuilder
    private func planPrice(_ plan: Plan, product: Product?, isHero: Bool) -> some View {
        if let product {
            if plan == .lifetime {
                Text("\(product.displayPrice) \(PricingConfig.lifetimeOnceSuffix)")
                    .font(.title3.weight(.semibold).monospacedDigit())
            } else {
                Text(product.displayPrice)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        } else {
            ProgressView().controlSize(.small)
                .tint(isHero ? .white : nil)
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
        .disabled((selectedProduct == nil && !mockPaywallPrices)
                  || (selection == .lifetime && lifetimeDisplayPrice == nil)
                  || isProcessing)
    }

    private var purchaseButtonTitle: String {
        // Route through the unit-tested pure helper so the CTA is consistent with
        // the logic covered by PaywallCopyTests. In marketing-screenshot mode there
        // are no real products, so force intro-eligible (the strongest CTA) the same
        // way the old inline code did. lifetimeDisplayPrice nil-guards so the
        // Lifetime CTA never produces a bare trailing "— " string.
        let tier = PaywallCopy.Tier(rawValue: selection.rawValue) ?? .yearly
        let introEligible = mockPaywallPrices || manager.eligibleForIntroOffer
        return PaywallCopy.ctaTitle(for: tier,
                                    lifetimePrice: lifetimeDisplayPrice,
                                    eligibleForIntroOffer: introEligible)
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

    /// Resolved localized display price for the Lifetime tier, feeding both the
    /// CTA button title (`"Buy Lifetime — <price>"`) and the CTA's disable guard
    /// (a nil value disables the button so it never shows a bare trailing "— ").
    /// Real path: the loaded StoreKit product's localized price string. Mock path
    /// (`--mock-paywall-prices`, no live products): falls back to `"$99.99"` so
    /// the CTA renders correctly in marketing screenshots / demos. nil ⇒ disable.
    private var lifetimeDisplayPrice: String? {
        if let lifetime = manager.lifetime { return lifetime.displayPrice }
        return mockPaywallPrices ? "$99.99" : nil
    }

    /// When the user already owns Lifetime, the body's `!ownsLifetime` guard
    /// suppresses the picker + CTA + trialTerms; this renders the owned-state
    /// label (the double-buy guard) in their place. Lifetime is otherwise a
    /// first-class row in `pricePicker`, so there is no demoted affordance.
    @ViewBuilder
    private var lifetimeAffordance: some View {
        if manager.ownsLifetime {
            Label(PricingConfig.ownedTitle, systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
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
