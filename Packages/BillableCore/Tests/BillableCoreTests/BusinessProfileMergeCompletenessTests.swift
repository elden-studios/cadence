import Testing
@testable import BillableCore

@Suite("merge completeness")
struct BusinessProfileMergeCompletenessTests {
    /// Tripwire: if someone adds a stored property to BusinessProfile, this fails so they
    /// consciously decide whether reconcile's copyUserFields must carry it. Update BOTH the
    /// count here AND copyUserFields when intentionally adding a field.
    @Test("stored-property count is locked")
    func storedPropertyCountLocked() {
        let mirror = Mirror(reflecting: BusinessProfile(name: "x"))
        #expect(mirror.children.count == BusinessProfile.expectedStoredPropertyCount)
    }
}
