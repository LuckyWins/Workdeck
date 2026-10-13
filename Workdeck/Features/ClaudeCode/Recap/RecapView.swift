import SwiftUI

/// Last week's recap in the expanded notch (weekly recap spec §3, statistics spec §4).
struct RecapView: View {
    let recap: WeeklyRecapSummary
    let thresholds: [Int]
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private let calendar = RecapCalendar.calendar()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("\(RecapText.title) · \(RecapText.weekRange(recap.weekStart, calendar: calendar))")
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecapText.duration(recap.seconds))
                        .font(.system(size: 26, weight: .semibold))
                    Text(RecapText.sessions(recap.sessions))
                        .foregroundStyle(Terminal.dim)
                }
                Spacer(minLength: 0)
                RecapMiniChart(recap: recap, calendar: calendar)
            }
            .padding(.vertical, 4)
            HStack(spacing: 0) {
                Text("\(RecapText.number(recap.files)) files  ")
                Text("+\(RecapText.number(recap.added))").foregroundStyle(.green)
                Text(" ")
                Text("\u{2212}\(RecapText.number(recap.removed))").foregroundStyle(.red)
            }
            .lineLimit(1)
            // Two short lines: the card holds about 40 characters per line.
            Text("\(RecapText.number(recap.commands)) commands · \(RecapText.number(recap.agents)) agents")
                .lineLimit(1)
            if let longest = recap.longest {
                row("longest", "\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
            if !recap.topProjects.isEmpty {
                header("top projects")
                ForEach(recap.topProjects, id: \.name) { project in
                    HStack(spacing: 6) {
                        Text("■").foregroundStyle(RecapPalette.color(RecapPalette.slot(of: project.name, in: recap)))
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
                            .foregroundStyle(RecapPalette.peakColor(account.weeklyPeak, thresholds: thresholds))
                    }
                }
            }
            HStack(spacing: 6) {
                Spacer()
                button("Details…", action: onDetails)
                button(RecapText.dismiss, action: onDismiss)
            }
            .padding(.top, 4)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
            .pointerStyle(.link)
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            // The rule takes what is left; the title never wraps.
            Text("─ \(title)").fixedSize()
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

/// Monday to Sunday, stacked by project in the palette colors (statistics spec §4).
struct RecapMiniChart: View {
    static let height: CGFloat = 38
    static let barWidth: CGFloat = 10

    let recap: WeeklyRecapSummary
    let calendar: Calendar

    var body: some View {
        let peak = max(recap.days.map(\.seconds).max() ?? 0, 1)
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(recap.days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 0) {
                        // The top project sits at the bottom of the bar.
                        ForEach(Array(RecapPalette.stack(day, in: recap).reversed()), id: \.name) { part in
                            Rectangle()
                                .fill(RecapPalette.color(RecapPalette.slot(of: part.name, in: recap)))
                                .frame(height: Self.height * part.seconds / peak)
                        }
                    }
                    .frame(width: Self.barWidth, height: Self.height, alignment: .bottom)
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(recap.days.enumerated()), id: \.offset) { _, day in
                    Text(RecapText.dayName(day.date, calendar: calendar).prefix(1))
                        .frame(width: Self.barWidth)
                }
            }
            .font(Terminal.font(9))
            .foregroundStyle(Terminal.dim)
        }
    }
}
