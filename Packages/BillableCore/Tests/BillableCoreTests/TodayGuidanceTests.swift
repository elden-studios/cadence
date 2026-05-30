import Testing
@testable import BillableCore

@Suite("TodayGuidance precedence")
struct TodayGuidanceTests {

    // MARK: Tier 1 — name banner wins over everything

    @Test("missing name wins even when setup incomplete and not enriched")
    func nameBeatsAll() {
        #expect(
            TodayGuidance.resolve(
                hasName: false, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .nameBanner
        )
    }

    @Test("missing name wins even when setup is complete")
    func nameBeatsGetStartedAndEnrichment() {
        #expect(
            TodayGuidance.resolve(
                hasName: false, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: false
            ) == .nameBanner
        )
    }

    // MARK: Tier 2 — get-started (onboarded, name present, setup not yet reached)

    @Test("named but setup not reached → get-started")
    func getStartedWhenNotSetUp() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .getStarted
        )
    }

    @Test("get-started outranks enrichment while setup unreached")
    func getStartedBeatsEnrichment() {
        // Not enriched AND not snoozed would qualify for enrichment, but setup
        // isn't reached yet, so get-started takes precedence.
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .getStarted
        )
    }

    // MARK: Tier 3 — enrichment (named, setup reached, not enriched, not snoozed)

    @Test("named + set up + not enriched + not snoozed → enrichment")
    func enrichmentWhenIncomplete() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: false
            ) == .enrichment
        )
    }

    @Test("snoozing the enrichment nudge suppresses it → none")
    func snoozeSuppressesEnrichment() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: true
            ) == .none
        )
    }

    // MARK: Tier 4 — none

    @Test("fully enriched → none")
    func noneWhenEnriched() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: true, enrichmentSnoozed: false
            ) == .none
        )
    }

    @Test("enriched + snoozed is still none (no double-suppression bug)")
    func noneWhenEnrichedAndSnoozed() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: true, enrichmentSnoozed: true
            ) == .none
        )
    }

    // MARK: Exhaustive — all 16 boolean combinations have a deterministic answer

    @Test("all 16 input combinations resolve deterministically per the precedence ladder")
    func fullTruthTable() {
        for hasName in [true, false] {
            for hasActiveSetup in [true, false] {
                for isEnriched in [true, false] {
                    for enrichmentSnoozed in [true, false] {
                        let got = TodayGuidance.resolve(
                            hasName: hasName, hasActiveSetup: hasActiveSetup,
                            isEnriched: isEnriched, enrichmentSnoozed: enrichmentSnoozed
                        )
                        let expected: TodayGuidance.Element
                        if !hasName {
                            expected = .nameBanner
                        } else if !hasActiveSetup {
                            expected = .getStarted
                        } else if !isEnriched && !enrichmentSnoozed {
                            expected = .enrichment
                        } else {
                            expected = .none
                        }
                        #expect(got == expected, "mismatch for \(hasName),\(hasActiveSetup),\(isEnriched),\(enrichmentSnoozed)")
                    }
                }
            }
        }
    }
}
