import SwiftUI
import SwiftData
import Charts
import BillableCore

/// Pro-only screen: a single-screen view of hours, earnings, billable mix,
/// uninvoiced amount, and an 8-week trend chart.
struct ReportsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allEntries: [TimeEntry]
    @Query private var allInvoices: [Invoice]
    @Query private var profiles: [BusinessProfile]

    @State private var range: ReportsAggregator.TimeRange = .thisMonth
    @State private var showingShareCSV = false
    @State private var csvURL: URL?

    private var snapshot: ReportsAggregator.Snapshot {
        ReportsAggregator.snapshot(
            entries: allEntries,
            in: range,
            currencyCode: profiles.first?.currencyCode ?? "USD"
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    rangePicker
                    headlineNumbers
                    if snapshot.totalHours == 0 {
                        emptyState
                    } else {
                        billableMix
                        clientBars
                        earningsTrend
                        projectBreakdown
                    }
                    uninvoicedCallout
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
        }
    }

    // MARK: - Sections

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(ReportsAggregator.TimeRange.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    private var headlineNumbers: some View {
        HStack(spacing: 12) {
            tile(label: "HOURS",
                 value: formatHours(snapshot.totalHours),
                 color: .blue)
            tile(label: "EARNED",
                 value: snapshot.totalEarnings.formatted(.currency(code: snapshot.currencyCode)),
                 color: .green)
        }
    }

    private func tile(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var billableMix: some View {
        let billable = (snapshot.billableHours as NSDecimalNumber).doubleValue
        let nonBillable = (snapshot.nonBillableHours as NSDecimalNumber).doubleValue
        let total = billable + nonBillable
        if total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Billable vs non-billable")
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: max(20, CGFloat(billable / total) * 320))
                    Rectangle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: max(0, CGFloat(nonBillable / total) * 320))
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    legend(color: .green, label: "Billable \(formatHours(snapshot.billableHours))")
                    Spacer()
                    legend(color: .gray, label: "Non-billable \(formatHours(snapshot.nonBillableHours))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    @ViewBuilder
    private var clientBars: some View {
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

    @ViewBuilder
    private var earningsTrend: some View {
        if !snapshot.earningsTrend.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Earnings — last 8 weeks")
                Chart {
                    ForEach(snapshot.earningsTrend) { point in
                        BarMark(
                            x: .value("Week", point.weekStart, unit: .weekOfYear),
                            y: .value("Earnings", (point.amount as NSDecimalNumber).doubleValue)
                        )
                        .foregroundStyle(Color.green.gradient)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var projectBreakdown: some View {
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
                            Text(row.amount.formatted(.currency(code: snapshot.currencyCode)))
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

    private var uninvoicedCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNINVOICED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.uninvoicedAmount.formatted(.currency(code: snapshot.currencyCode)))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Spacer()
            }
            Text("All-time outstanding work, ready to invoice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
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
            // Step 7 polish: surface as toast.
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func formatHours(_ hours: Decimal) -> String {
        let totalSeconds = (hours as NSDecimalNumber).doubleValue * 3600
        let totalMinutes = Int(totalSeconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}
