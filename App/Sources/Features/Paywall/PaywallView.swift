import SwiftUI
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
    enum Trigger {
        case reports
        case settings
        case removeWatermark  // NEW

        var headline: String {
            switch self {
            case .reports:         "See your full picture."
            case .settings:        "Go Pro."
            case .removeWatermark: "Remove the watermark."
            }
        }
        var subhead: String {
            switch self {
            case .reports:         "Hours by client, billable vs. non-billable, earnings trends — all in one screen."
            case .settings:        "Watermark-free invoices, full Reports, CSV exports."
            case .removeWatermark: "Pro removes 'Sent with Cadence' from your invoice PDFs and unlocks Reports + CSV export."
            }
        }
    }

    let trigger: Trigger
    @State private var manager = SubscriptionManager.shared
    @State private var selection: Plan = .yearly
    @State private var isProcessing = false
    @State private var error: String?

    enum Plan: String, CaseIterable { case yearly, monthly }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headerSection
                    valueBullets
                    pricePicker
                    purchaseButton
                    secondaryActions
                    finePrint
                }
                .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close paywall")
                }
            }
            .task { manager.start() }
            .alert("Couldn't complete purchase", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Sections

    private var headerSection: some View {
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

    private var valueBullets: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("doc.text", "Watermark-free PDF invoices",
                   "Send polished invoices without 'Sent with Cadence' in the footer.")
            bullet("chart.bar", "Reports & insights",
                   "Hours by client, billable vs. non-billable, earnings trends.")
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

    @ViewBuilder
    private func planRow(_ plan: Plan) -> some View {
        let isSelected = selection == plan
        let product: Product? = (plan == .yearly) ? manager.yearly : manager.monthly

        Button {
            selection = plan
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(plan == .yearly ? "Yearly" : "Monthly")
                            .font(.headline)
                        if plan == .yearly {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(perCycleLabel(for: plan, product: product))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let product {
                    Text(product.displayPrice)
                        .font(.title3.weight(.semibold).monospacedDigit())
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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
            return "Billed every month"
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
        .disabled(selectedProduct == nil || isProcessing)
    }

    private var purchaseButtonTitle: String {
        manager.eligibleForIntroOffer ? "Start 7-day free trial" : "Subscribe"
    }

    private var secondaryActions: some View {
        HStack {
            Button("Restore purchases") {
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
        selection == .yearly ? manager.yearly : manager.monthly
    }

    private func runPurchase() async {
        guard let product = selectedProduct else { return }
        isProcessing = true
        defer { isProcessing = false }
        let outcome = await manager.purchase(product)
        switch outcome {
        case .success:
            dismiss()
        case .pending, .userCancelled:
            break
        case .failed(let message):
            error = message
        }
    }

    private func restore() async {
        isProcessing = true
        defer { isProcessing = false }
        let restored = await manager.restore()
        if restored { dismiss() }
    }
}
