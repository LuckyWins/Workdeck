import SwiftUI

/// Last week's recap in the expanded notch (weekly recap spec §3).
struct RecapView: View {
    let recap: WeeklyRecapSummary
    let thresholds: [Int]
    let onDismiss: () -> Void

    private let calendar = RecapCalendar.calendar()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("\(RecapText.title) · \(RecapText.weekRange(recap.weekStart, calendar: calendar))")
            Text("\(RecapText.duration(recap.seconds)) coding · \(RecapText.number(recap.sessions)) sessions · \(RecapText.number(recap.agents)) agents")
            HStack(spacing: 0) {
                Text("\(RecapText.number(recap.files)) files  ")
                Text("+\(RecapText.number(recap.added))").foregroundStyle(.green)
                Text(" ")
                Text("\u{2212}\(RecapText.number(recap.removed))").foregroundStyle(.red)
                Text(" · \(RecapText.number(recap.commands)) commands")
            }
            if let busiest = recap.busiest {
                row("busiest", "\(RecapText.dayName(busiest.date, calendar: calendar)) · \(RecapText.duration(busiest.seconds))")
            }
            if let longest = recap.longest {
                row("longest", "\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
            if !recap.topProjects.isEmpty {
                header("top projects")
                ForEach(recap.topProjects, id: \.name) { project in
                    HStack {
                        Text(project.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(RecapText.duration(project.seconds)).foregroundStyle(Terminal.dim)
                    }
                }
            }
            if !recap.accounts.isEmpty {
                header("limits")
                ForEach(recap.accounts, id: \.name) { account in
                    HStack {
                        Text(account.name).foregroundStyle(.purple)
                        Spacer(minLength: 6)
                        Text("5h hit \(account.hits)×").foregroundStyle(Terminal.dim)
                        Text("7d peak \(Int(account.weeklyPeak.rounded()))%")
                            .foregroundStyle(peakColor(account.weeklyPeak))
                    }
                }
            }
            HStack {
                Spacer()
                Button(RecapText.dismiss, action: onDismiss)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                    .pointerStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    /// The weekly peak takes the limit bars' threshold colors.
    private func peakColor(_ percent: Double) -> Color {
        let window = UsageWindow(kind: .sevenDay, usedPercent: percent, resetsAt: recap.weekStart)
        return LimitsPresentation.level(of: window, thresholds: thresholds).notchColor
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text("─ \(title)")
            Rectangle().fill(Terminal.faint).frame(height: 1)
        }
        .foregroundStyle(Terminal.dim)
        .padding(.top, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label.padding(toLength: 10, withPad: " ", startingAt: 0)).foregroundStyle(Terminal.dim)
            Text(value).lineLimit(1).truncationMode(.tail)
        }
    }
}
