import SwiftUI
import WidgetKit
import ActivityKit
import BillableCore

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            lockScreenView(context: context)
                .padding()
                .activityBackgroundTint(.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(context.attributes.clientColor.swiftUIColor)
                            .frame(width: 10, height: 10)
                        Text(context.attributes.clientName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                         pauseTime: nil, countsDown: false)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(context.attributes.clientColor.swiftUIColor)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.projectName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Image(systemName: "timer")
                        Text("Running")
                            .font(.caption)
                        Spacer()
                        Text("Tap to open")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(context.attributes.clientColor.swiftUIColor)
                    .frame(width: 14, height: 14)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                     pauseTime: nil, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 56)
            } minimal: {
                Circle()
                    .fill(context.attributes.clientColor.swiftUIColor)
            }
            .keylineTint(context.attributes.clientColor.swiftUIColor)
        }
    }

    private func lockScreenView(context: ActivityViewContext<TimerActivityAttributes>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(context.attributes.clientColor.swiftUIColor)
                        .frame(width: 10, height: 10)
                    Text(context.attributes.clientName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text(context.attributes.projectName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
            Text(timerInterval: context.state.startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                 pauseTime: nil, countsDown: false)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(context.attributes.clientColor.swiftUIColor)
        }
    }
}
