import SwiftUI
import SwiftData
import BillableCore

/// Two-screen first-launch flow: welcome → identity (choose how you bill + enter
/// your name). On finish it mutates the canonical `BusinessProfile` and stamps
/// `onboardingCompletedAt` — it creates NO Client/Project/TimeEntry. The user lands
/// on Today and is guided to first value there (spec §5/§7).
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var entityType: EntityType = .freelancer   // pre-select Freelancer (spec §5)
    @State private var name: String = ""
    @State private var showingSaveError = false

    enum Step { case welcome, identity }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // Content scrolls so the keyboard cannot occlude the name field on
                // small devices (SE); the CTA stays pinned in the safe area.
                ScrollView {
                    content
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                }
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Couldn't save", isPresented: $showingSaveError) {
            Button("Try Again") { finish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We couldn't save your profile. Please try again.")
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 10/255, green: 18/255, blue: 36/255),
                Color(red: 28/255, green: 44/255, blue: 80/255),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcomeScreen
        case .identity: identityScreen
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 60)
            iconHero
                .frame(width: 140, height: 140)
            VStack(spacing: 10) {
                Text("Cadence")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                // PRESERVE VERBATIM — guarded by LaunchTaglineUITests.
                Text("Track hours.\nSend invoices.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Made for freelancers and small businesses.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 40)
        }
    }

    private var identityScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("How do you bill?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text("This sets up your invoice labels. You can change it later in Settings.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 12) {
                ForEach(EntityType.allCases, id: \.self) { type in
                    entityCard(type)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(entityType.issuerNameLabel.uppercased())
                TextField(
                    "",
                    text: $name,
                    prompt: Text(entityType.issuerNamePrompt).foregroundStyle(.white.opacity(0.55))
                )
                .textContentType(entityType.nameContentType)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { if primaryEnabled { finish() } }
                .padding(14)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                .foregroundStyle(.white)
                .accessibilityIdentifier("onboarding.nameField")
            }
            Spacer(minLength: 24)
        }
    }

    private func entityCard(_ type: EntityType) -> some View {
        let isSelected = entityType == type
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { entityType = type }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: type.cardSystemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? Color.orange : .white.opacity(0.7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(type.cardTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(type.cardSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                // Selected state = border + fill + checkmark (NOT color-alone; spec §5/§9).
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.orange : .white.opacity(0.3))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                (isSelected ? Color.orange.opacity(0.12) : Color.white.opacity(0.06)),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.orange : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(type.cardTitle). \(type.cardSubtitle)")
        .accessibilityHint(isSelected ? "Selected" : "Double-tap to choose")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var iconHero: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.68, blue: 0.25),
                                 Color(red: 1, green: 0.47, blue: 0.24)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .padding(8)
                .rotationEffect(.degrees(-30))
            Circle()
                .fill(Color(red: 1, green: 0.94, blue: 0.82))
                .frame(width: 18, height: 18)
                .offset(x: 50, y: 22)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        Button {
            advance()
        } label: {
            Text(primaryLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color(red: 1, green: 0.68, blue: 0.25),
                                     Color(red: 1, green: 0.47, blue: 0.24)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
                .foregroundStyle(.black.opacity(0.85))
        }
        .disabled(!primaryEnabled)
        .opacity(primaryEnabled ? 1 : 0.4)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:  "Get started"
        case .identity: "Finish setup"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .welcome:  return true
        case .identity: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Behavior

    private func advance() {
        switch step {
        case .welcome:
            withAnimation(reduceMotion ? nil : .snappy) { step = .identity }
            // Do NOT auto-focus on appear — that would hide the cards behind the
            // keyboard. Focus only after the user has reached the identity step.
        case .identity:
            finish()
        }
    }

    /// Crash-safe, throwing save (spec §5). Fetch-then-mutate the canonical profile;
    /// insert a fresh one ONLY if none exists. Set the one-way latch only AFTER the
    /// user fields save successfully. Creates no Client/Project/TimeEntry.
    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let profile = BusinessProfileStore.canonical(in: modelContext)
            ?? {
                let fresh = BusinessProfile.defaultForCurrentLocale()
                modelContext.insert(fresh)
                return fresh
            }()

        profile.name = trimmed
        profile.entityType = entityType
        profile.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Surface a retry instead of silently dropping the user's input.
            showingSaveError = true
            return
        }

        // Latch only after a confirmed save; a best-effort second save persists it.
        profile.onboardingCompletedAt = .now
        try? modelContext.save()
        UserDefaults.standard.set(true, forKey: OnboardingFlags.completedKey)
        onFinish()
    }
}

enum OnboardingFlags {
    static let completedKey = "cadence.onboarding.completed"

    /// Onboarding is done when ANY profile has `onboardingCompletedAt` set (the
    /// CloudKit-synced source of truth) OR the local fast-path flag is set (covers
    /// the same device before a sync round-trip). The legacy `clientCount == 0`
    /// branch is DELETED: the new flow no longer seeds a client, so it would
    /// falsely re-trigger onboarding for a finished user who has no clients yet
    /// (spec §5).
    static func shouldShow(in context: ModelContext) -> Bool {
        if UserDefaults.standard.bool(forKey: completedKey) { return false }
        let completed = (try? context.fetchCount(
            FetchDescriptor<BusinessProfile>(
                predicate: #Predicate { $0.onboardingCompletedAt != nil }
            )
        )) ?? 0
        return completed == 0
    }
}
