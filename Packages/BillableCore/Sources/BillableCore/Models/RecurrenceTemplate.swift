import Foundation
import SwiftData

/// Mirrored @Model. A user-defined rule that, on a schedule, generates a
/// draft invoice from tracked time.
@Model
public final class RecurrenceTemplate {
    @Attribute(.unique) public var id: UUID

    /// No `@Relationship(deleteRule: .cascade)` — Client deletion cascades to
    /// `RecurrenceTemplate` rows explicitly in `ClientsView.deleteClient` (Phase 6
    /// fix for F10). The explicit cascade is necessary so the Scheduler
    /// cancellation can run alongside the delete; a `.cascade` relationship would
    /// skip that logic.
    public var client: Client?

    /// `RecurrenceCadence.rawValue` — stored as String for SwiftData/CloudKit safety.
    public var cadence: String

    /// `RangeRule.rawValue`. v1.1 derives this from cadence at creation;
    /// stored for clarity and future decoupling.
    public var rangeRule: String

    /// `LineItemGrouping.rawValue`.
    public var grouping: String

    /// Notes template with merge fields `{month} {year} {clientName}`.
    public var notesTemplate: String?

    /// Next scheduled fire date — computed forward by `RecurrenceService`.
    public var nextFireDate: Date

    /// Most recent user-acknowledged materialization. Advanced by
    /// `RecurrenceService.materializeDraft` (NOT by the Scheduler when the
    /// iOS notification fires) so missed fires surface as catch-up work.
    public var lastFiredAt: Date?

    /// Optional auto-stop. Once reached, `isEnded(now:)` returns true and
    /// the template stops being materialized.
    public var endDate: Date?

    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        client: Client?,
        cadence: RecurrenceCadence,
        rangeRule: RangeRule? = nil,
        grouping: LineItemGrouping,
        notesTemplate: String? = nil,
        nextFireDate: Date,
        endDate: Date? = nil,
        isActive: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.client = client
        self.cadence = cadence.rawValue
        self.rangeRule = (rangeRule ?? RangeRule.implied(from: cadence)).rawValue
        self.grouping = grouping.rawValue
        self.notesTemplate = notesTemplate
        self.nextFireDate = nextFireDate
        self.lastFiredAt = nil
        self.endDate = endDate
        self.isActive = isActive
        self.createdAt = createdAt
    }

    // MARK: - Typed accessors

    public var cadenceValue: RecurrenceCadence {
        get { RecurrenceCadence.from(raw: cadence) ?? .monthly(dayOfMonth: 1) }
        set { cadence = newValue.rawValue }
    }

    public var rangeRuleValue: RangeRule {
        get { RangeRule(rawValue: rangeRule) ?? .previousMonth }
        set { rangeRule = newValue.rawValue }
    }

    public var groupingValue: LineItemGrouping {
        get { LineItemGrouping(rawValue: grouping) ?? .perEntry }
        set { grouping = newValue.rawValue }
    }

    /// `true` if `endDate` has been reached and the recurrence should stop firing.
    public func isEnded(now: Date = .now) -> Bool {
        guard let endDate else { return false }
        return endDate <= now
    }
}
