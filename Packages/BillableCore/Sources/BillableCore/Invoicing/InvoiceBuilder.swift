import Foundation
import SwiftData

/// How to roll up `TimeEntry` rows into `InvoiceLineItem` rows on the invoice.
public enum LineItemGrouping: String, CaseIterable, Identifiable, Sendable {
    /// One line item per `TimeEntry`.
    case perEntry
    /// One line item per `Project`, summing hours across all entries in the range.
    case perProject

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .perEntry:   "Per entry"
        case .perProject: "Per project"
        }
    }
}

/// Constructs and finalizes invoices from tracked time. Pure functions over
/// `ModelContext` — same shape as `TimerService`.
public enum InvoiceBuilder {

    public enum BuilderError: Error, Equatable {
        case noBusinessProfile
        case noUninvoicedEntries
        case noEligibleEntries
    }

    /// Fetch the entries that should land on an invoice for `client` over `range`.
    /// Excludes: non-billable, archived projects (defensive), already-invoiced,
    /// still-running entries.
    ///
    /// Uses a simple SwiftData fetch + Swift-side filter rather than a deeply
    /// chained `#Predicate` through `project.client.persistentModelID`, because
    /// that path through optional relationships triggers fragile predicate
    /// compilation under parallel test runs.
    @MainActor
    public static func eligibleEntries(
        for client: Client,
        in range: InvoiceDateRange,
        context: ModelContext
    ) -> [TimeEntry] {
        let start = range.start
        let end = range.end
        let clientID = client.persistentModelID

        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { entry in
                entry.invoiceID == nil
                && entry.endedAt != nil
                && entry.startedAt < end
                && entry.startedAt >= start
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        return entries.filter { entry in
            guard let project = entry.project,
                  let entryClient = project.client else { return false }
            return entryClient.persistentModelID == clientID && project.isBillable
        }
    }

    /// Like `eligibleEntries(for client:)` but scoped to a single `project`.
    @MainActor
    public static func eligibleEntries(
        for project: Project,
        in range: InvoiceDateRange,
        context: ModelContext
    ) -> [TimeEntry] {
        let start = range.start
        let end = range.end
        let projectID = project.persistentModelID
        guard project.isBillable else { return [] }

        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { entry in
                entry.invoiceID == nil
                && entry.endedAt != nil
                && entry.startedAt < end
                && entry.startedAt >= start
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        return entries.filter { $0.project?.persistentModelID == projectID }
    }

    /// The `client`'s non-archived projects that have ≥1 eligible entry in `range`.
    /// Sorted by name. Powers the "Invoice all projects" action and picker enablement.
    @MainActor
    public static func projectsWithEligibleEntries(
        for client: Client,
        in range: InvoiceDateRange,
        context: ModelContext
    ) -> [Project] {
        let entries = eligibleEntries(for: client, in: range, context: context)
        var seen = Set<PersistentIdentifier>()
        var projects: [Project] = []
        for entry in entries {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted { projects.append(project) }
        }
        return projects.sorted { $0.name < $1.name }
    }

    /// Build line items WITHOUT persisting anything. Used by the preview screen.
    public static func buildLineItems(
        from entries: [TimeEntry],
        grouping: LineItemGrouping,
        roundMinutes: Int = 1
    ) -> [InvoiceLineItem] {
        switch grouping {
        case .perEntry:
            return entries.compactMap { entry in
                guard let project = entry.project else { return nil }
                let hours = roundedHours(entry.duration(), toMinutes: roundMinutes)
                guard hours > 0 else { return nil }
                let description = lineDescription(for: entry, project: project)
                return InvoiceLineItem(
                    description: description,
                    hours: hours,
                    hourlyRate: project.hourlyRate,
                    sourceTimeEntryRef: entry.persistentModelID.storeIdentifier
                )
            }
        case .perProject:
            let groups = Dictionary(grouping: entries) { $0.project?.persistentModelID }
            return groups.compactMap { (_, entriesForProject) in
                guard let project = entriesForProject.first?.project else { return nil }
                let totalSeconds = entriesForProject.reduce(into: TimeInterval(0)) {
                    $0 += $1.duration()
                }
                let hours = roundedHours(totalSeconds, toMinutes: roundMinutes)
                guard hours > 0 else { return nil }
                let dateLabel = projectDateRangeLabel(entriesForProject)
                return InvoiceLineItem(
                    description: "\(project.name) — \(dateLabel)",
                    hours: hours,
                    hourlyRate: project.hourlyRate,
                    sourceTimeEntryRef: nil
                )
            }
            .sorted { $0.description < $1.description }
        }
    }

    /// Create a Draft invoice in the model context using snapshots from `client`
    /// and `profile`. Does NOT transition status — caller decides when to Send.
    @MainActor
    public static func createDraft(
        for client: Client,
        lineItems: [InvoiceLineItem],
        project: Project? = nil,
        scopeOfWork: String? = nil,
        notes: String? = nil,
        issuedAt: Date = .now,
        profile: BusinessProfile,
        context: ModelContext
    ) throws -> Invoice {
        guard !lineItems.isEmpty else { throw BuilderError.noEligibleEntries }

        let dueAt = Calendar.current.date(
            byAdding: .day,
            value: profile.defaultDueAfterDays,
            to: issuedAt
        ) ?? issuedAt

        let invoice = Invoice(
            number: profile.previewNextInvoiceNumber,
            issuedAt: issuedAt,
            dueAt: dueAt,
            status: .draft,
            clientNameSnapshot: client.name,
            clientAddressSnapshot: client.address,
            clientEmailSnapshot: client.email,
            clientColor: client.color,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: profile.address,
            issuerEmailSnapshot: profile.email,
            issuerLogoSnapshot: profile.logoData,
            issuerBankBeneficiaryNameSnapshot: profile.bankBeneficiaryName,
            issuerBankNameSnapshot: profile.bankName,
            issuerBankLocationSnapshot: profile.bankLocation,
            issuerBankIBANSnapshot: profile.bankIBAN,
            issuerBankSWIFTSnapshot: profile.bankSWIFT,
            issuerTaxIDLabelSnapshot: profile.taxIDLabel,
            issuerTaxIDNumberSnapshot: profile.taxIDNumber,
            paymentTermsSnapshot: profile.paymentTerms,
            taxLabelSnapshot: profile.taxLabel,
            taxRateSnapshot: profile.taxRate,
            currencyCodeSnapshot: profile.currencyCode,
            lineItems: lineItems,
            notes: notes,
            client: client,
            project: project,
            projectNameSnapshot: project?.name,
            scopeOfWork: scopeOfWork
        )
        context.insert(invoice)
        try context.save()
        return invoice
    }

    /// Move a Draft invoice to Sent, consume the next invoice number on the
    /// profile, and mark each contributing TimeEntry with `invoiceID` so it's
    /// excluded from future invoices and the "uninvoiced" total.
    @MainActor
    public static func finalizeAndSend(
        _ invoice: Invoice,
        sourceEntries: [TimeEntry],
        profile: BusinessProfile,
        at sentAt: Date = .now,
        context: ModelContext
    ) throws {
        // Re-stamp with the issuer's actual next number (preview value may now be stale).
        invoice.number = profile.consumeNextInvoiceNumber()
        try invoice.markSent(at: sentAt)
        for entry in sourceEntries {
            entry.invoiceID = invoice.uuid
            entry.updatedAt = sentAt
        }
        try context.save()
    }

    // MARK: - Helpers

    /// Round `seconds` to the nearest `roundMinutes`, returning hours as Decimal.
    /// 1-minute rounding (the default) preserves precision; 15-min rounding suits
    /// agencies that bill in quarter-hour increments (future toggle).
    private static func roundedHours(_ seconds: TimeInterval, toMinutes: Int) -> Decimal {
        guard seconds > 0 else { return 0 }
        let stepSeconds = Double(max(1, toMinutes) * 60)
        let snapped = (seconds / stepSeconds).rounded() * stepSeconds
        return Decimal(snapped / 3600)
    }

    private static func lineDescription(for entry: TimeEntry, project: Project) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let day = formatter.string(from: entry.startedAt)
        if let notes = entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            return "\(project.name) — \(day) — \(notes)"
        }
        return "\(project.name) — \(day)"
    }

    private static func projectDateRangeLabel(_ entries: [TimeEntry]) -> String {
        guard let earliest = entries.map(\.startedAt).min(),
              let latest = entries.compactMap(\.endedAt).max() ?? entries.map(\.startedAt).max() else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let from = formatter.string(from: earliest)
        let to = formatter.string(from: latest)
        return from == to ? from : "\(from) – \(to)"
    }
}
