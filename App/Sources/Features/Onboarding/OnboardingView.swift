import SwiftUI
import SwiftData
import BillableCore

/// Three-screen first-launch flow: welcome → first client → start a timer.
/// On finish, creates a `Client`, a default `Project`, and (if the user opts)
/// starts a running `TimeEntry` so the next thing they see is a live timer.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    let onFinish: () -> Void

    @State private var step: Step = .welcome

    @State private var clientName: String = ""
    @State private var hourlyRateInput: Double = 100
    @State private var clientColor: ClientColor = .blue
    @State private var projectName: String = "General"

    enum Step: Int { case welcome, client, timer }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
            VStack(spacing: 0) {
                stepIndicator
                    .padding(.top, 24)
                content
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
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

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(i <= step.rawValue ? Color.orange : Color.white.opacity(0.25))
                    .frame(width: i == step.rawValue ? 28 : 8, height: 6)
                    .animation(.snappy, value: step)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcomeScreen
        case .client:   clientScreen
        case .timer:    timerScreen
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 22) {
            Spacer()
            iconHero
                .frame(width: 140, height: 140)
            VStack(spacing: 10) {
                Text("Cadence")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                Text("Track hours.\nSend invoices.\nGet paid.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Made for freelancers and consultants.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    private var clientScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your first client")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text("You can add more later. Each client gets their own rate and color.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("CLIENT NAME")
                TextField("", text: $clientName, prompt: Text("Acme Corp").foregroundStyle(.white.opacity(0.3)))
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("HOURLY RATE")
                HStack {
                    Text("$")
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("", value: $hourlyRateInput, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .foregroundStyle(.white)
                    Text("/hr")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(14)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("COLOR")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 10), spacing: 10) {
                    ForEach(ClientColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(.white, lineWidth: clientColor == color ? 3 : 0)
                            )
                            .onTapGesture { clientColor = color }
                    }
                }
            }
            Spacer()
        }
    }

    private var timerScreen: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 16) {
                Circle()
                    .fill(clientColor.swiftUIColor.opacity(0.18))
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(clientColor.swiftUIColor)
                    )
                    .frame(width: 110, height: 110)
                Text("Start your first timer")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text("We'll create a project called \"\(displayProjectName)\" under \(clientNameDisplay) and start tracking right away.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("PROJECT NAME")
                TextField("", text: $projectName, prompt: Text("General").foregroundStyle(.white.opacity(0.3)))
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
            }
            Spacer()
        }
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

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if step != .welcome {
                Button {
                    advance(back: true)
                } label: {
                    Text("Back")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Button {
                advance(back: false)
            } label: {
                HStack(spacing: 6) {
                    Text(primaryLabel)
                    if step != .timer {
                        Image(systemName: "arrow.right")
                    }
                }
                .font(.headline)
                .frame(minWidth: 180)
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
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
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: "Get started"
        case .client:  "Next"
        case .timer:   "Start tracking"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .welcome: return true
        case .client:  return !clientName.trimmingCharacters(in: .whitespaces).isEmpty && hourlyRateInput > 0
        case .timer:   return !displayProjectName.isEmpty
        }
    }

    private var displayProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "General" : trimmed
    }

    private var clientNameDisplay: String {
        let trimmed = clientName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "your client" : trimmed
    }

    // MARK: - Behavior

    private func advance(back: Bool) {
        if back {
            if let prev = Step(rawValue: step.rawValue - 1) {
                step = prev
            }
            return
        }
        switch step {
        case .welcome:
            step = .client
        case .client:
            step = .timer
        case .timer:
            finish()
        }
    }

    private func finish() {
        // Create BusinessProfile if missing (we'll let user fill in details from Settings later).
        if (try? modelContext.fetch(FetchDescriptor<BusinessProfile>()))?.isEmpty != false {
            let profile = BusinessProfile()
            modelContext.insert(profile)
        }
        let client = Client(name: clientName.trimmingCharacters(in: .whitespaces), color: clientColor)
        let project = Project(
            name: displayProjectName,
            hourlyRate: Decimal(hourlyRateInput),
            isBillable: true,
            client: client
        )
        modelContext.insert(client)
        modelContext.insert(project)
        try? modelContext.save()
        if let entry = try? TimerService.start(project: project, in: modelContext) {
            Task { await TimerActivityController.shared.startActivity(for: entry) }
        }
        UserDefaults.standard.set(true, forKey: OnboardingFlags.completedKey)
        onFinish()
    }
}

enum OnboardingFlags {
    static let completedKey = "cadence.onboarding.completed"

    static func shouldShow(in context: ModelContext) -> Bool {
        if UserDefaults.standard.bool(forKey: completedKey) { return false }
        let clientCount = (try? context.fetchCount(FetchDescriptor<Client>())) ?? 0
        return clientCount == 0
    }
}
