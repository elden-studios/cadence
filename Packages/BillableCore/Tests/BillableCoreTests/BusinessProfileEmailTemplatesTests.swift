import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("BusinessProfile email templates")
@MainActor
struct BusinessProfileEmailTemplatesTests {

    @Test("Default BusinessProfile() carries the default invoice email templates")
    func defaultsArePresent() {
        let profile = BusinessProfile()
        #expect(profile.invoiceEmailSubjectTemplate == BusinessProfile.defaultInvoiceEmailSubject)
        #expect(profile.invoiceEmailBodyTemplate == BusinessProfile.defaultInvoiceEmailBody)
    }

    @Test("Custom templates are preserved through init")
    func customPreserved() {
        let profile = BusinessProfile(
            invoiceEmailSubjectTemplate: "INV {invoiceNumber}",
            invoiceEmailBodyTemplate: "Hi"
        )
        #expect(profile.invoiceEmailSubjectTemplate == "INV {invoiceNumber}")
        #expect(profile.invoiceEmailBodyTemplate == "Hi")
    }

    @Test("Default templates contain {invoiceNumber} and {senderName} merge fields")
    func defaultsUseMergeFields() {
        #expect(BusinessProfile.defaultInvoiceEmailSubject.contains("{invoiceNumber}"))
        #expect(BusinessProfile.defaultInvoiceEmailSubject.contains("{senderName}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{invoiceNumber}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{senderName}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{amount}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{dueDate}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{clientFirstName}"))
    }

    @Test("ReminderTemplateRenderer correctly renders default invoice email subject")
    func defaultSubjectRenders() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(name: "Studio Lina")
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue, email: "billing@acme.example")
        context.insert(client)
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: client.name,
            clientEmailSnapshot: client.email,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        let rendered = ReminderTemplateRenderer.render(
            template: profile.invoiceEmailSubjectTemplate,
            invoice: invoice,
            senderName: profile.name
        )
        #expect(rendered == "Invoice INV-0042 from Studio Lina")
    }

    @Test("effective…Template falls back to default when stored value is empty or whitespace")
    func effectiveTemplateFallsBackOnEmpty() {
        let profile = BusinessProfile(
            invoiceEmailSubjectTemplate: "",
            invoiceEmailBodyTemplate: "   \n\t  "
        )
        #expect(profile.effectiveInvoiceEmailSubjectTemplate == BusinessProfile.defaultInvoiceEmailSubject)
        #expect(profile.effectiveInvoiceEmailBodyTemplate == BusinessProfile.defaultInvoiceEmailBody)
    }

    @Test("effective…Template returns the stored value unchanged when non-empty")
    func effectiveTemplatePreservesNonEmpty() {
        let profile = BusinessProfile(
            invoiceEmailSubjectTemplate: "Custom subject for {invoiceNumber}",
            invoiceEmailBodyTemplate: "Custom body"
        )
        #expect(profile.effectiveInvoiceEmailSubjectTemplate == "Custom subject for {invoiceNumber}")
        #expect(profile.effectiveInvoiceEmailBodyTemplate == "Custom body")
    }

    @Test("Default body template renders all merge fields end-to-end with no unsubstituted braces")
    func defaultBodyRendersCleanly() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(name: "Studio Lina")
        context.insert(profile)
        let client = Client(name: "Acme Corp", color: .blue, contactName: "Pat Smith")
        context.insert(client)
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: Date(timeIntervalSinceReferenceDate: 760_000_000),
            clientNameSnapshot: client.name,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
            client: client
        )
        let rendered = ReminderTemplateRenderer.render(
            template: profile.invoiceEmailBodyTemplate,
            invoice: invoice,
            senderName: profile.name
        )
        // No unsubstituted braces left behind
        #expect(!rendered.contains("{clientFirstName}"))
        #expect(!rendered.contains("{invoiceNumber}"))
        #expect(!rendered.contains("{amount}"))
        #expect(!rendered.contains("{dueDate}"))
        #expect(!rendered.contains("{senderName}"))
        // Concrete values present
        #expect(rendered.contains("Pat"))               // clientFirstName
        #expect(rendered.contains("INV-0042"))           // invoiceNumber
        #expect(rendered.contains("Studio Lina"))        // senderName
    }
}
