import SwiftUI

/// The kept weeks as green squares above the Statistics window's week (activity grid spec §2).
struct ActivityGridView: View {
    let grid: ActivityGrid
    /// The week shown below the grid; its column is outlined.
    let shownWeek: Date
    let calendar: Calendar
    /// A square's date; the controller shows its week.
    let onSelect: (Date) -> Void

    nonisolated static let gap: CGFloat = 3
    nonisolated static let maxCell: CGFloat = 14
    /// The weekday labels' column with its spacing.
    nonisolated static let labelWidth: CGFloat = 24
    private static let monthRowHeight: CGFloat = 13
    private static let rowSpacing: CGFloat = 3

    /// The largest square size that fits `columns` in `width`, at most `maxCell`.
    nonisolated static func cellSize(width: CGFloat, columns: Int) -> CGFloat {
        guard columns > 0 else { return maxCell }
        let available = width - labelWidth - CGFloat(columns - 1) * gap
        return max(4, min(maxCell, (available / CGFloat(columns)).rounded(.down)))
    }

    /// The square under `point` in the squares' own coordinates; a point in a gap belongs to the nearer square, so
    /// sweeping across the grid never drops the tooltip between squares.
    nonisolated static func square(at point: CGPoint, cell: CGFloat, columns: Int) -> (column: Int, row: Int)? {
        let pitch = cell + gap
        let column = Int(((point.x + gap / 2) / pitch).rounded(.down))
        let row = Int(((point.y + gap / 2) / pitch).rounded(.down))
        guard point.x >= -gap / 2, point.y >= -gap / 2, (0..<columns).contains(column), (0..<7).contains(row) else { return nil }
        return (column, row)
    }

    /// Where a tooltip goes, decided from the square's position and the widest tooltip, so it never depends on the
    /// width of the tooltip shown before.
    nonisolated enum TooltipPlacement: Equatable {
        /// Leading edge at `x`, beside the square.
        case right(x: CGFloat)
        /// Trailing edge at `trailing`, beside the square.
        case left(trailing: CGFloat)
        /// Under the square's row, leading edge at `x`: neither side has room, and the square stays visible.
        case below(x: CGFloat)
    }

    nonisolated static let tooltipMaxWidth: CGFloat = 220
    nonisolated static let tooltipSpacing: CGFloat = 6

    nonisolated static func tooltipPlacement(cellX: CGFloat, cell: CGFloat, width: CGFloat) -> TooltipPlacement {
        let right = cellX + cell + tooltipSpacing
        if right + tooltipMaxWidth <= width {
            return .right(x: right)
        }
        let trailing = cellX - tooltipSpacing
        if trailing - tooltipMaxWidth >= 0 {
            return .left(trailing: trailing)
        }
        return .below(x: max(0, min(cellX, width - tooltipMaxWidth)))
    }

    /// Level 0 neutral, levels 1–4 the system green getting stronger (spec §2.3).
    static func fill(level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.18)
        case 1: Color.green.opacity(0.32)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.78)
        default: Color.green
        }
    }

    @State private var width: CGFloat = 368
    @State private var hoveredDate: Date?

    private var cell: CGFloat {
        Self.cellSize(width: width, columns: grid.weeks.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            monthRow
            HStack(alignment: .top, spacing: 0) {
                weekdayLabels
                columns
            }
            footer
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .topLeading) { tooltip }
    }

    // MARK: Labels (§2.2)

    private var monthRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.months, id: \.column) { month in
                Text(month.name)
                    .offset(x: Self.labelWidth + CGFloat(month.column) * (cell + Self.gap))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: Self.monthRowHeight, maxHeight: Self.monthRowHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var weekdayLabels: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row.isMultiple(of: 2) ? weekdayName(row) : "")
                    .font(.system(size: min(9, cell)))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth - 4, height: cell, alignment: .leading)
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func weekdayName(_ row: Int) -> String {
        guard let day = grid.weeks.first?.days[row] else { return "" }
        return RecapText.dayName(day.date, calendar: calendar)
    }

    // MARK: Squares (§2.2–§2.5, §2.7)

    private var columns: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(grid.weeks, id: \.start) { week in
                VStack(spacing: Self.gap) {
                    ForEach(week.days, id: \.date) { day in
                        squareView(day, isShown: week.start == shownWeek)
                    }
                }
                .overlay {
                    if week.start == shownWeek {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary, lineWidth: 1.5)
                            .padding(-1.5)
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let hit = Self.square(at: point, cell: cell, columns: grid.weeks.count)
                let day = hit.map { grid.weeks[$0.column].days[$0.row] }
                hoveredDate = day.flatMap { $0.isFuture ? nil : $0.date }
            case .ended:
                hoveredDate = nil
            }
        }
        .pointerStyle(.link)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity")
    }

    /// A plain button, so Full Keyboard Access and VoiceOver reach every square; the shown week's squares are selected.
    private func squareView(_ day: ActivityDay, isShown: Bool) -> some View {
        Button {
            onSelect(day.date)
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.fill(level: day.level))
                .opacity(day.isFuture ? 0.4 : 1)
                .overlay {
                    if hoveredDate == day.date {
                        RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.7), lineWidth: 1)
                    }
                }
                .frame(width: cell, height: cell)
                // Half a gap on each side, so a click between squares lands on the nearer one, as hover does.
                .padding(Self.gap / 2)
                .contentShape(Rectangle())
                .padding(-Self.gap / 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RecapText.accessibleDay(day.date, seconds: day.seconds, isFuture: day.isFuture, calendar: calendar))
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }

    // MARK: Tooltip (§2.4)

    private var hovered: (day: ActivityDay, column: Int, row: Int)? {
        guard let hoveredDate else { return nil }
        for (column, week) in grid.weeks.enumerated() {
            if let row = week.days.firstIndex(where: { $0.date == hoveredDate }) {
                return (week.days[row], column, row)
            }
        }
        return nil
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered {
            let cellX = Self.labelWidth + CGFloat(hovered.column) * (cell + Self.gap)
            let cellY = Self.monthRowHeight + Self.rowSpacing + CGFloat(hovered.row) * (cell + Self.gap)
            Group {
                switch Self.tooltipPlacement(cellX: cellX, cell: cell, width: width) {
                case .right(let x):
                    tooltipContent(hovered.day)
                        .offset(x: x, y: max(0, cellY - 4))
                case .left(let trailing):
                    // A frame ending at `trailing` puts the tooltip's trailing edge there without measuring it.
                    tooltipContent(hovered.day)
                        .frame(width: trailing, alignment: .topTrailing)
                        .offset(y: max(0, cellY - 4))
                case .below(let x):
                    tooltipContent(hovered.day)
                        .offset(x: x, y: cellY + cell + Self.tooltipSpacing)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func tooltipContent(_ day: ActivityDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if day.seconds > 0 {
                Text("\(RecapText.dayDate(day.date, calendar: calendar)) · \(RecapText.duration(day.seconds))")
                    .fontWeight(.semibold)
                ForEach(day.projects, id: \.name) { project in
                    HStack(spacing: 4) {
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(RecapText.duration(project.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(RecapText.dayDate(day.date, calendar: calendar))
                    .fontWeight(.semibold)
                Text(RecapText.noCoding)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(minWidth: 140, maxWidth: Self.tooltipMaxWidth, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Line under the grid (§2.6)

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                stats
                Spacer(minLength: 0)
                legend
            }
            VStack(alignment: .leading, spacing: 4) {
                stats
                legend
            }
        }
    }

    private var stats: some View {
        Text("\(emphasized(RecapText.streak(grid.streak))) · \(emphasized(RecapText.activeDays(grid.activeDays)))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// "9 day streak" with the number in the primary color.
    private func emphasized(_ text: String) -> Text {
        guard let space = text.firstIndex(of: " ") else { return Text(text) }
        return Text("\(Text(text[..<space]).foregroundStyle(.primary))\(String(text[space...]))")
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
                .padding(.trailing, 2)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.fill(level: level))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .padding(.leading, 2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(RecapText.activityLegendHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: \(RecapText.activityLegendHelp)")
    }
}
