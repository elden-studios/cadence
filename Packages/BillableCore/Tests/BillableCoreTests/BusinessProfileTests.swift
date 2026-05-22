import Foundation
import Testing
@testable import BillableCore

@Suite("BusinessProfile invoice numbering")
struct BusinessProfileNumberingTests {
    @Test("consumeNextInvoiceNumber formats with prefix and zero-padded 4-digit number")
    func formatAndAdvance() {
        let profile = BusinessProfile(invoiceNumberPrefix: "INV-", nextInvoiceNumber: 7)
        #expect(profile.previewNextInvoiceNumber == "INV-0007")
        #expect(profile.consumeNextInvoiceNumber() == "INV-0007")
        #expect(profile.nextInvoiceNumber == 8)
        #expect(profile.consumeNextInvoiceNumber() == "INV-0008")
        #expect(profile.nextInvoiceNumber == 9)
    }

    @Test("Custom prefix is respected")
    func customPrefix() {
        let profile = BusinessProfile(invoiceNumberPrefix: "STUDIO-", nextInvoiceNumber: 100)
        #expect(profile.consumeNextInvoiceNumber() == "STUDIO-0100")
    }

    @Test("Numbers larger than 4 digits still render (no truncation)")
    func largeNumbers() {
        let profile = BusinessProfile(invoiceNumberPrefix: "INV-", nextInvoiceNumber: 12345)
        #expect(profile.consumeNextInvoiceNumber() == "INV-12345")
    }
}

@Suite("ClientColor")
struct ClientColorTests {
    @Test("Raw values are stable string identifiers")
    func rawValuesStable() {
        #expect(ClientColor.blue.rawValue == "blue")
        #expect(ClientColor.indigo.rawValue == "indigo")
    }

    @Test("All cases provide a non-empty hex string")
    func allHaveHex() {
        for color in ClientColor.allCases {
            #expect(color.hex.hasPrefix("#"))
            #expect(color.hex.count == 7)
        }
    }

    @Test("Round-trip via raw value preserves the case")
    func roundTrip() {
        for color in ClientColor.allCases {
            let restored = ClientColor(rawValue: color.rawValue)
            #expect(restored == color)
        }
    }
}
