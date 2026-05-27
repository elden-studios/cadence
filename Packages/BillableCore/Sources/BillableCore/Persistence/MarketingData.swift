import Foundation
import SwiftData

/// Curated demo data for App Store screenshots.
///
/// Seeded via the `--seed-marketing` launch argument. The container is an
/// isolated App Group (no CloudKit) so this data never touches a user's
/// iCloud account.
public enum MarketingData {

    @MainActor
    public static func seed(in context: ModelContext, referenceDate: Date = .now) {
        let cal = Calendar.current

        // MARK: - Business Profile (USD — global appeal for App Store screenshots)
        let profile = BusinessProfile(
            name: "Studio Lina",
            address: "456 Atlantic Ave\nBrooklyn, NY 11217",
            email: "hello@studiolina.co",
            phone: "+1 (555) 010-0420",
            paymentTerms: "Net 14",
            defaultDueAfterDays: 14,
            invoiceNumberPrefix: "INV-",
            nextInvoiceNumber: 12,                       // suggests prior history
            taxLabel: "Sales Tax",
            taxRate: Decimal(string: "0.0875")!,
            currencyCode: "USD",
            bankBeneficiaryName: "Studio Lina LLC",
            bankName: "Chase Bank",
            bankLocation: "New York, USA",
            bankIBAN: "US33 2100 0000 1000 2003 4567",
            bankSWIFT: "CHASUS33"
        )
        context.insert(profile)

        // MARK: - Clients
        let northwind = Client(
            name: "Northwind Design",
            color: .indigo,
            contactName: "Riley Chen",
            email: "riley@northwind.example"
        )
        let apex = Client(
            name: "Apex Analytics",
            color: .blue,
            contactName: "Jordan Ali",
            email: "jordan@apex-analytics.example"
        )
        let helio = Client(
            name: "Helio Labs",
            color: .orange,
            contactName: "Sam Vargas",
            email: "sam@heliolabs.example"
        )
        let pinecone = Client(
            name: "Pinecone Studio",
            color: .teal,
            contactName: "Avery Park",
            email: "avery@pinecone.example"
        )
        [northwind, apex, helio, pinecone].forEach(context.insert)

        // MARK: - Projects
        let northwindWeb = Project(name: "Website Refresh", hourlyRate: 145, isBillable: true, client: northwind)
        let northwindBrand = Project(name: "Brand System", hourlyRate: 165, isBillable: true, client: northwind)
        let apexDashboard = Project(name: "Dashboard MVP", hourlyRate: 175, isBillable: true, client: apex)
        let helioAudit = Project(name: "App Store Audit", hourlyRate: 140, isBillable: true, client: helio)
        let helioSite = Project(name: "Marketing Site", hourlyRate: 125, isBillable: true, client: helio)
        let pineconeLogo = Project(name: "Logo Identity", hourlyRate: 110, isBillable: true, client: pinecone)
        [northwindWeb, northwindBrand, apexDashboard, helioAudit, helioSite, pineconeLogo].forEach(context.insert)

        // MARK: - Timeline today
        let today9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: referenceDate)!
        let today10_30 = cal.date(byAdding: .minute, value: 90, to: today9)!
        let today11 = cal.date(byAdding: .minute, value: 30, to: today10_30)!
        let today12_15 = cal.date(byAdding: .minute, value: 75, to: today11)!
        let today13 = cal.date(byAdding: .minute, value: 45, to: today12_15)!
        let today14_45 = cal.date(byAdding: .minute, value: 105, to: today13)!
        let today15 = cal.date(byAdding: .minute, value: 15, to: today14_45)!
        let today15_45 = cal.date(byAdding: .minute, value: 45, to: today15)!
        // A running timer started 25 minutes before referenceDate.
        let runningStart = cal.date(byAdding: .minute, value: -25, to: referenceDate)!

        let todayEntries: [TimeEntry] = [
            TimeEntry(startedAt: today9,      endedAt: today10_30, notes: "Hero mockups", project: northwindWeb),
            TimeEntry(startedAt: today10_30,  endedAt: today11,    notes: "Mark exploration", project: pineconeLogo),
            TimeEntry(startedAt: today11,     endedAt: today12_15, notes: "Filter UI iteration", project: apexDashboard),
            TimeEntry(startedAt: today13,     endedAt: today14_45, notes: "Landing copy + structure", project: helioSite),
            TimeEntry(startedAt: today15,     endedAt: today15_45, notes: "Color token system", project: northwindBrand),
            // Running timer — most-recent and currently active for the Today screenshot.
            TimeEntry(startedAt: runningStart, endedAt: nil,       notes: "Empty states pass", project: apexDashboard),
        ]
        todayEntries.forEach(context.insert)

        // MARK: - Yesterday (1 entry)
        if let yesterday = cal.date(byAdding: .day, value: -1, to: referenceDate) {
            let y9 = cal.date(bySettingHour: 9,  minute: 30, second: 0, of: yesterday)!
            let y13 = cal.date(bySettingHour: 13, minute: 0, second: 0, of: yesterday)!
            context.insert(TimeEntry(startedAt: y9, endedAt: y13, notes: "Brand audit + research", project: northwindBrand))
        }

        // MARK: - Two days ago (2 entries)
        if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: referenceDate) {
            let t10 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: twoDaysAgo)!
            let t12 = cal.date(byAdding: .hour, value: 2, to: t10)!
            let t14 = cal.date(byAdding: .hour, value: 2, to: t12)!
            let t17 = cal.date(byAdding: .hour, value: 3, to: t14)!
            context.insert(TimeEntry(startedAt: t10, endedAt: t12, notes: "Audit kickoff", project: helioAudit))
            context.insert(TimeEntry(startedAt: t14, endedAt: t17, notes: "Dashboard wireframes", project: apexDashboard))
        }

        // MARK: - Invoices
        // Sent + paid invoice (Northwind, last billing cycle)
        let lastMonth = cal.date(byAdding: .day, value: -21, to: referenceDate)!
        let sentInvoice = Invoice(
            number: "INV-0010",
            issuedAt: lastMonth,
            dueAt: cal.date(byAdding: .day, value: 14, to: lastMonth)!,
            status: .paid,
            clientNameSnapshot: northwind.name,
            clientAddressSnapshot: "812 Main St\nBrooklyn, NY",
            clientEmailSnapshot: northwind.email,
            clientColor: .indigo,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: profile.address,
            issuerEmailSnapshot: profile.email,
            issuerBankBeneficiaryNameSnapshot: "Studio Lina LLC",
            issuerBankNameSnapshot: "Chase Bank",
            issuerBankLocationSnapshot: "New York, USA",
            issuerBankIBANSnapshot: "US33 2100 0000 1000 2003 4567",
            issuerBankSWIFTSnapshot: "CHASUS33",
            paymentTermsSnapshot: profile.paymentTerms,
            taxLabelSnapshot: profile.taxLabel,
            taxRateSnapshot: profile.taxRate,
            currencyCodeSnapshot: profile.currencyCode,
            lineItems: [
                InvoiceLineItem(
                    description: "Website Refresh — Apr 1–14",
                    hours: 18,
                    hourlyRate: 145
                ),
                InvoiceLineItem(
                    description: "Brand System — Apr 8–14",
                    hours: 6,
                    hourlyRate: 165
                ),
            ],
            notes: "Thanks for the partnership.",
            client: northwind
        )
        context.insert(sentInvoice)

        // Draft invoice (Apex, current period)
        let draftInvoice = Invoice(
            number: "INV-0011",
            issuedAt: referenceDate,
            dueAt: cal.date(byAdding: .day, value: 14, to: referenceDate)!,
            status: .draft,
            clientNameSnapshot: apex.name,
            clientAddressSnapshot: "55 Innovation Park\nAustin, TX",
            clientEmailSnapshot: apex.email,
            clientColor: .blue,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: profile.address,
            issuerEmailSnapshot: profile.email,
            issuerBankBeneficiaryNameSnapshot: "Studio Lina LLC",
            issuerBankNameSnapshot: "Chase Bank",
            issuerBankLocationSnapshot: "New York, USA",
            issuerBankIBANSnapshot: "US33 2100 0000 1000 2003 4567",
            issuerBankSWIFTSnapshot: "CHASUS33",
            paymentTermsSnapshot: profile.paymentTerms,
            taxLabelSnapshot: profile.taxLabel,
            taxRateSnapshot: profile.taxRate,
            currencyCodeSnapshot: profile.currencyCode,
            lineItems: [
                InvoiceLineItem(
                    description: "Dashboard MVP — May 1–26",
                    hours: 24,
                    hourlyRate: 175
                ),
            ],
            client: apex
        )
        context.insert(draftInvoice)

        context.saveOrLog("seed marketing data")
    }
}
