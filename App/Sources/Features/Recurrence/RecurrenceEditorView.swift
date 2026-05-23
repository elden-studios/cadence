import SwiftUI
import SwiftData
import BillableCore

struct RecurrenceEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let template: RecurrenceTemplate

    @State private var cadenceKind: RecurrenceCadenceKind
    @State private var dayOfMonth: Int
    @State private var weekday: RecurrenceCadence.Weekday
    @State private var endDate: Date?
    @State private var hasEndDate: Bool
    @State private var notesTemplate: String
    @State private var grouping: LineItemGrouping
    @State private var generatingNow: Bool = false
    @State private var errorMessage: String?

    init(template: RecurrenceTemplate) {
        self.template = template
        let initialCadence = template.cadenceValue
        _cadenceKind = State(initialValue: RecurrenceCadenceKind(initialCadence))
        switch initialCadence {
        case .monthly(let d):
            _dayOfMonth = State(initialValue: d)
            _weekday    = State(initialValue: .monday)
        case .weekly(let w):
            _dayOfMonth = State(initialValue: 1)
            _weekday    = State(initialValue: w)
        case .biweekly(let w):
            _dayOfMonth = State(initialValue: 1)
            _weekday    = State(initialValue: w)
        }
        _endDate       = State(initialValue: template.endDate)
        _hasEndDate    = State(initialValue: template.endDate != nil)
        _notesTemplate = State(initialValue: template.notesTemplate ?? "")
        _grouping      = State(initialValue: template.groupingValue)
    }

    var body: some View {
        Form {
            Section("Client") {
                LabeledContent("Client", value: template.client?.name ?? "—")
            }

            Section("Cadence") {
                Picker("Frequency", selection: $cadenceKind) {
                    ForEach(RecurrenceCadenceKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch cadenceKind {
                case .monthly:
                    Picker("Day of month", selection: $dayOfMonth) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                case .weekly, .biweekly:
                    Picker("Day of week", selection: $weekday) {
                        ForEach([RecurrenceCadence.Weekday.monday, .tuesday, .wednesday,
                                 .thursday, .friday, .saturday, .sunday], id: \.rawValue) { w in
                            Text(w.rawValue.capitalized).tag(w)
                        }
                    }
                }
            }

            Section("End date") {
                Toggle("Has end date", isOn: $hasEndDate)
                if hasEndDate {
                    DatePicker(
                        "End",
                        selection: Binding(
                            get: { endDate ?? Date() },
                            set: { endDate = $0 }
                        ),
                        displayedComponents: [.date]
                    )
                }
            }

            Section("Invoice template") {
                Picker("Grouping", selection: $grouping) {
                    ForEach(LineItemGrouping.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                TextField("Notes (supports {month} {year} {clientName})",
                          text: $notesTemplate, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Button {
                    Task { await generateNow() }
                } label: {
                    HStack {
                        if generatingNow { ProgressView() }
                        Text("Generate now")
                    }
                }
                .disabled(generatingNow)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Recurring schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        let cadence: RecurrenceCadence = switch cadenceKind {
        case .monthly:  .monthly(dayOfMonth: dayOfMonth)
        case .weekly:   .weekly(weekday: weekday)
        case .biweekly: .biweekly(weekday: weekday)
        }
        template.cadenceValue = cadence
        template.rangeRuleValue = RangeRule.implied(from: cadence)
        template.groupingValue = grouping
        template.notesTemplate = notesTemplate.isEmpty ? nil : notesTemplate
        template.endDate = hasEndDate ? endDate : nil
        template.nextFireDate = RecurrenceService.computeNextFireDate(
            cadence: cadence, after: Date()
        )
        // TODO(Task 5.4): JIT permission ask when Scheduler.schedule is wired in here.
        // Today this saves the template; the actual notification scheduling happens
        // when Phase 4/5 hooks Scheduler.schedule into the save path.
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func generateNow() async {
        generatingNow = true
        defer { generatingNow = false }
        do {
            _ = try RecurrenceService.materializeDraft(
                template: template, now: .now, context: modelContext
            )
            dismiss()
        } catch RecurrenceService.MaterializationError.noBusinessProfile {
            errorMessage = "Set up your business profile first."
        } catch RecurrenceService.MaterializationError.noClient {
            errorMessage = "This template's client was deleted. Please remove the template."
        } catch RecurrenceService.MaterializationError.ended {
            errorMessage = "This template has ended."
        } catch {
            errorMessage = "Couldn't generate: \(error.localizedDescription)"
        }
    }
}

