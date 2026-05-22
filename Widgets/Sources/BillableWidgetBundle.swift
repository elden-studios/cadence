import SwiftUI
import WidgetKit

@main
struct BillableWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
        CurrentTimerWidget()
        TodaySummaryWidget()
    }
}
