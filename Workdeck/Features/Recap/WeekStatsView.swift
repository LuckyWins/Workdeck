import SwiftUI

/// The notch's Stats tab (notch tabs spec §5): the current week as a recap card, without Got it; before anything was
/// recorded, the header and one dim line.
struct WeekStatsView: View {
    let summary: WeeklyRecapSummary?
    let thresholds: [Int]
    let onDetails: () -> Void

    private let calendar = RecapCalendar.calendar()

    var body: some View {
        if let summary, summary.seconds > 0 {
            RecapView(recap: summary, thresholds: thresholds, title: RecapText.thisWeekTitle, onDetails: onDetails, onDismiss: nil)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                RecapCardParts.header(summary.map { "\(RecapText.thisWeekTitle) · \(RecapText.weekRange($0.weekStart, calendar: calendar))" } ?? RecapText.thisWeekTitle)
                Text(RecapText.nothingThisWeek)
                    .foregroundStyle(Terminal.dim)
                    .padding(.vertical, 4)
                HStack {
                    Spacer()
                    RecapCardParts.button("Details…", action: onDetails)
                }
            }
        }
    }
}
