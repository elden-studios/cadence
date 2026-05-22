import SwiftUI
import BillableCore

/// Container for the day timeline. Hosts the day/week navigation strip on top
/// and the spatial DayTimelineView underneath.
struct TimelineScreen: View {
    @State private var selectedDay: Date
    @State private var snap: TimelineSnap = .fifteenMinutes

    init(day: Date = .now) {
        _selectedDay = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        VStack(spacing: 0) {
            weekStrip
            Divider()
            DayTimelineView(day: selectedDay, snap: snap)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Snap", selection: $snap) {
                        ForEach(TimelineSnap.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .gesture(daySwipeGesture)
    }

    private var navigationTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: selectedDay)
    }

    // MARK: - Week strip

    private var weekStrip: some View {
        let days = weekDays(centered: selectedDay)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                    Button {
                        withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: day) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(weekdayShort(day))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("\(Calendar.current.component(.day, from: day))")
                                .font(.headline)
                        }
                        .frame(width: 44, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func weekDays(centered day: Date) -> [Date] {
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfMonth, for: day) else {
            return [day]
        }
        return (0..<7).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: weekInterval.start)
        }
    }

    private func weekdayShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    // MARK: - Day swipe

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Only horizontal swipes (not vertical scrolls)
                guard abs(dx) > abs(dy) * 2, abs(dx) > 60 else { return }
                let delta = dx < 0 ? 1 : -1
                if let new = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) {
                    withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: new) }
                }
            }
    }
}
