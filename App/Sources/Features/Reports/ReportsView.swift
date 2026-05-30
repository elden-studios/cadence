import SwiftUI
import SwiftData
import Charts
import BillableCore

/// Pro-only screen: an AR-led financial dashboard (Layout A). Money lenses
/// (Tracked / Invoiced / Collected) → an "as of today" accounts-receivable card →
/// performance KPIs → a range-aware Invoiced revenue chart → hours-by-client and
/// project breakdown. Every figure derives from a memoized `ReportsAggregator`
/// snapshot recomputed only when its inputs change.
struct ReportsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allEntries: [TimeEntry]
    @Query private var allInvoices: [Invoice]
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    @State private var range: ReportsAggregator.TimeRange = .thisMonth
    @State private var showingShareCSV = false
    @State private var csvURL: URL?
    @State private var exportError: String?

    /// Cached snapshot. Recomputed on input change (range / entries / invoices),
    /// never per `body` evaluation. SwiftData republishes the `@Query` arrays only
    /// on a real content change (an invoice marked paid, a rate edited), so this
    /// won't churn per render.
    @State private var snapshot: ReportsAggregator.Snapshot?

    private var currencyCode: String { profiles.first?.currencyCode ?? "USD" }

    private func recompute() {
        snapshot = ReportsAggregator.snapshot(
            entries: allEntries,
            invoices: allInvoices,
            in: range,
            activeCurrency: currencyCode
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    rangePicker
                    if let snapshot {
                        moneyLenses(snapshot)
                        arCard(snapshot)
                        performanceTiles(snapshot)
                        if snapshot.totalHours == 0 && snapshot.revenueTrend.isEmpty {
                            emptyState
                        } else {
                            revenueTrendChart(snapshot)
                            clientBars(snapshot)
                            projectBreakdown(snapshot)
                        }
                        if snapshot.excludedCurrencyCount > 0 {
                            excludedCurrencyFootnote(snapshot.excludedCurrencyCount)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export CSV")
                }
            }
            .sheet(isPresented: $showingShareCSV) {
                if let csvURL {
                    ShareSheet(items: [csvURL]).ignoresSafeArea()
                }
            }
            .alert("Couldn't export", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .onAppear { recompute() }
            .onChange(of: range) { recompute() }
            .onChange(of: allEntries) { recompute() }
            .onChange(of: allInvoices) { recompute() }
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(ReportsAggregator.TimeRange.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Money lenses (Tracked / Invoiced / Collected) — no connecting arrows

    private func moneyLenses(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        HStack(spacing: 12) {
            tile(label: "TRACKED",
                 value: currency(snapshot.money.tracked, code: snapshot.currencyCode),
                 color: .secondary)
            tile(label: "INVOICED",
                 value: currency(snapshot.money.invoiced, code: snapshot.currencyCode),
                 color: .blue)
            tile(label: "COLLECTED",
                 value: currency(snapshot.money.collected, code: snapshot.currencyCode),
                 color: .green)
        }
    }

    private func tile(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    // MARK: - AR card ("get paid") — as-of-today snapshot with graceful states

    @ViewBuilder
    private func arCard(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        let ar = snapshot.ar
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GET PAID")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("as of today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if ar.outstanding == 0 && snapshot.money.invoiced == 0 {
                // No receivable data at all.
                Text("No invoices yet — track time, then invoice to see what you're owed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ar.outstanding == 0 {
                // Everything paid.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("All paid up")
                        .font(.title2.weight(.bold))
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                if snapshot.money.collected > 0 {
                    Text("\(currency(snapshot.money.collected, code: snapshot.currencyCode)) collected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Outstanding money — show the lead figure.
                Text(currency(ar.outstanding, code: snapshot.currencyCode))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())

                if ar.overdue > 0 {
                    overduePill(ar, code: snapshot.currencyCode)
                } else {
                    Text("On track")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let avg = ar.avgDaysToPay {
                    Label("~\(Int(avg.rounded())) days to pay", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                agingBar(ar)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    private func overduePill(_ ar: ReportsAggregator.ARSummary, code: String) -> some View {
        Text("\(currency(ar.overdue, code: code)) overdue · \(ar.overdueCount)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.red, in: Capsule())
    }

    /// Stacked aging segments. When nothing is overdue, the bar is a single
    /// "Current" segment (no empty 30/60/90 slots). Hidden entirely when there's
    /// no outstanding money (handled by the caller's branch).
    @ViewBuilder
    private func agingBar(_ ar: ReportsAggregator.ARSummary) -> some View {
        let aging = ar.aging
        let total = (aging.outstanding as NSDecimalNumber).doubleValue
        if total > 0 {
            let segments: [(label: String, value: Double, color: Color)] = [
                ("Current", (aging.current as NSDecimalNumber).doubleValue, .green),
                ("1–30", (aging.d1to30 as NSDecimalNumber).doubleValue, .yellow),
                ("31–60", (aging.d31to60 as NSDecimalNumber).doubleValue, .orange),
                ("60+", (aging.d60plus as NSDecimalNumber).doubleValue, .red),
            ].filter { $0.value > 0 }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(segments, id: \.label) { seg in
                            Rectangle()
                                .fill(seg.color)
                                .frame(width: max(2, CGFloat(seg.value / total) * geo.size.width))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if ar.overdue > 0 {
                    HStack(spacing: 12) {
                        ForEach(segments, id: \.label) { seg in
                            legend(color: seg.color, label: seg.label)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Performance KPIs (effective rate / utilization)

    private func performanceTiles(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        let perf = snapshot.performance
        let rateValue = perf.effectiveRate.map {
            "\(currency($0, code: snapshot.currencyCode))/h"
        } ?? "—"
        let utilValue = perf.utilization.map {
            $0.formatted(.percent.precision(.fractionLength(0)))
        } ?? "—"
        return HStack(spacing: 12) {
            tile(label: "EFFECTIVE RATE", value: rateValue, color: .primary)
            tile(label: "UTILIZATION", value: utilValue, color: .primary)
        }
    }

    // MARK: - Revenue trend (range-aware, Invoiced)

    @ViewBuilder
    private func revenueTrendChart(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        if !snapshot.revenueTrend.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Revenue")
                Chart {
                    ForEach(snapshot.revenueTrend) { point in
                        BarMark(
                            x: .value("Period", point.bucketStart, unit: chartUnit(snapshot.trendBucket)),
                            y: .value("Invoiced", (point.amount as NSDecimalNumber).doubleValue)
                        )
                        .foregroundStyle(Color.blue.gradient)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .stride(by: chartUnit(snapshot.trendBucket))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: trendAxisFormat(snapshot.trendBucket))
                    }
                }
            }
        }
    }

    private func chartUnit(_ bucket: ReportsAggregator.TrendBucket) -> Calendar.Component {
        switch bucket {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private func trendAxisFormat(_ bucket: ReportsAggregator.TrendBucket) -> Date.FormatStyle {
        switch bucket {
        case .day: .dateTime.month().day()
        case .week: .dateTime.month().day()
        case .month: .dateTime.month(.abbreviated)
        }
    }

    // MARK: - Hours by client (existing chart)

    @ViewBuilder
    private func clientBars(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        if !snapshot.clientHours.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Hours by client")
                Chart {
                    ForEach(snapshot.clientHours) { row in
                        BarMark(
                            x: .value("Hours", (row.hours as NSDecimalNumber).doubleValue),
                            y: .value("Client", row.clientName)
                        )
                        .foregroundStyle(
                            ClientColor(rawValue: row.clientColorRaw)?.swiftUIColor ?? .blue
                        )
                        .annotation(position: .trailing) {
                            Text(formatHours(row.hours))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: CGFloat(snapshot.clientHours.count) * 38 + 20)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis(.hidden)
            }
        }
    }

    // MARK: - Project breakdown (existing list)

    @ViewBuilder
    private func projectBreakdown(_ snapshot: ReportsAggregator.Snapshot) -> some View {
        if !snapshot.projectHours.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Hours by project")
                ForEach(snapshot.projectHours) { row in
                    HStack {
                        Circle()
                            .fill(ClientColor(rawValue: row.clientColorRaw)?.swiftUIColor ?? .blue)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.projectName).font(.subheadline.weight(.medium))
                            Text(row.clientName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatHours(row.hours))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if row.isBillable {
                            Text(currency(row.amount, code: snapshot.currencyCode))
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: - Footnotes / empty state

    private func excludedCurrencyFootnote(_ count: Int) -> some View {
        Text("\(count) invoice\(count == 1 ? "" : "s") in other currencies aren't included.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No tracked time in this range.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - CSV

    private func exportCSV() {
        let invoiceLookup = Dictionary(uniqueKeysWithValues: allInvoices.map { ($0.uuid, $0) })
        let rows = CSVExporter.rows(from: allEntries, invoiceLookup: invoiceLookup)
        let csv = CSVExporter.csv(for: rows)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BillableTimeEntries.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            csvURL = url
            showingShareCSV = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func currency(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code))
    }

    private func formatHours(_ hours: Decimal) -> String {
        let totalSeconds = (hours as NSDecimalNumber).doubleValue * 3600
        let totalMinutes = Int(totalSeconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}
