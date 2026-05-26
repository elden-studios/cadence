import Foundation
import SwiftData

/// Seed data helpers for tests and SwiftUI previews.
/// Never invoked in shipping app code.
public enum SampleData {
    @MainActor
    public static func seedDemo(in context: ModelContext, referenceDate: Date = .now) {
        let profile = BusinessProfile(
            name: "Studio Lina",
            address: "123 Studio Way\nBrooklyn, NY 11201",
            email: "hello@studiolina.example",
            phone: "+1 (555) 123-4567",
            paymentTerms: "Net 14",
            defaultDueAfterDays: 14,
            invoiceNumberPrefix: "INV-",
            nextInvoiceNumber: 1,
            taxLabel: "Tax",
            taxRate: Decimal(string: "0.0875")!,
            currencyCode: Locale.current.currency?.identifier ?? "USD"
        )
        context.insert(profile)

        let acme = Client(name: "Acme Corp", color: .indigo, contactName: "Pat Doe", email: "pat@acme.example")
        let zen = Client(name: "Zen Garden", color: .green, contactName: "Sam Lin")
        context.insert(acme)
        context.insert(zen)

        let acmeSite = Project(name: "Website Redesign", hourlyRate: 120, isBillable: true, client: acme)
        let acmeBrand = Project(name: "Brand Refresh", hourlyRate: 150, isBillable: true, client: acme)
        let zenLogo = Project(name: "Logo", hourlyRate: 95, isBillable: true, client: zen)
        let admin = Project(name: "Internal Admin", hourlyRate: 0, isBillable: false, client: zen)
        [acmeSite, acmeBrand, zenLogo, admin].forEach(context.insert)

        // A handful of completed entries today + this week
        let cal = Calendar.current
        let today9am = cal.date(bySettingHour: 9, minute: 0, second: 0, of: referenceDate)!
        let today10_30 = cal.date(byAdding: .minute, value: 90, to: today9am)!
        let today11 = cal.date(byAdding: .minute, value: 30, to: today10_30)!
        let today13 = cal.date(byAdding: .hour, value: 2, to: today11)!

        context.insert(TimeEntry(startedAt: today9am, endedAt: today10_30, notes: "Hero section", project: acmeSite))
        context.insert(TimeEntry(startedAt: today11, endedAt: today13, notes: "Logo exploration", project: zenLogo))

        // Yesterday on Acme brand
        if let yesterday = cal.date(byAdding: .day, value: -1, to: referenceDate) {
            let y9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!
            let y12 = cal.date(byAdding: .hour, value: 3, to: y9)!
            context.insert(TimeEntry(startedAt: y9, endedAt: y12, notes: "Brand audit", project: acmeBrand))
        }

        context.saveOrLog("seed sample data")
    }
}
