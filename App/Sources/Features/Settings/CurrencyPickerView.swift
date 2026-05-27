import SwiftUI
import SwiftData
import BillableCore

/// Standalone full-ISO currency picker reachable from Settings → Preferences.
/// Reads and writes `BusinessProfile.currencyCode`. If no profile exists yet
/// (rare — onboarding creates one), the first save creates one via
/// `BusinessProfile.defaultForCurrentLocale()`.
struct CurrencyPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]

    @State private var selection: String =
        Locale.current.currency?.identifier ?? "USD"
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Picker("Currency", selection: $selection) {
                ForEach(CurrencyCatalog.allCodes, id: \.self) { code in
                    Text("\(code) — \(CurrencyCatalog.displayName(for: code))")
                        .tag(code)
                }
            }
            .pickerStyle(.navigationLink)
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadIfNeeded() }
        .onChange(of: selection) { _, newValue in save(newValue) }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        if let existing = profiles.first?.currencyCode {
            selection = existing
        }
    }

    private func save(_ code: String) {
        let profile = profiles.first ?? {
            let p = BusinessProfile.defaultForCurrentLocale()
            modelContext.insert(p)
            return p
        }()
        profile.currencyCode = code
        profile.updatedAt = .now
        modelContext.saveOrLog("currency picker save")
    }
}
