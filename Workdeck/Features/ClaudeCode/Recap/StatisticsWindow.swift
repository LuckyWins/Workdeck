import Charts
import SwiftUI

/// One week of Claude Code work, Screen Time style (statistics spec §3).
struct StatisticsWindow: View {
    static let id = "claude-statistics"

    let controller: StatisticsController

    var body: some View {
        ScrollView {
            StatisticsContent(controller: controller)
        }
        .frame(minWidth: 400, minHeight: 480)
        // The week sits under the window title, where the toolbar cannot cover it.
        .navigationSubtitle(RecapText.weekRange(controller.weekStart, calendar: controller.calendar))
        .onAppear { controller.isVisible = true }
        .onDisappear { controller.isVisible = false }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    controller.goBack()
                } label: {
                    Label("Previous Week", systemImage: "chevron.left")
                }
                .disabled(!controller.canGoBack)
                Button("This Week") {
                    controller.showCurrentWeek()
                }
                .disabled(controller.isCurrentWeek)
                Button {
                    controller.goForward()
                } label: {
                    Label("Next Week", systemImage: "chevron.right")
                }
                .disabled(!controller.canGoForward)
            }
        }
    }
}

/// The window's page: headline, chart, projects, work and limits.
struct StatisticsContent: View {
    let controller: StatisticsController
    @Environment(\.openSettings) private var openSettings
    @State private var selectedDay: String?
    /// The project the Work section is filtered to; a click on its row again, or the chip's ×, clears it.
    @State private var selectedProject: String?
    @State private var hoveredProject: String?

    /// `selectedProject` and `selectedDay` start a page already filtered or hovered (snapshots).
    init(controller: StatisticsController, selectedProject: String? = nil, selectedDay: String? = nil) {
        self.controller = controller
        _selectedProject = State(initialValue: selectedProject)
        _selectedDay = State(initialValue: selectedDay)
    }

    private var summary: WeeklyRecapSummary {
        controller.summary
    }

    /// The selected project's figures while it is in the shown week.
    private var filter: RecapProjectSummary? {
        summary.projects.first { $0.name == selectedProject }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chart
                .padding(.top, 14)
            if summary.seconds > 0 {
                mostWorkedOn
                work
            }
            if !summary.accounts.isEmpty {
                limits
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: controller.weekStart) {
            selectedProject = nil
        }
    }

    // MARK: Header (§3.2, §3.5)

    /// The day under the pointer, while it has work; the header shows it instead of the week, as Screen Time does.
    private var hoveredDay: RecapDaySplit? {
        guard let selectedDay, let day = summary.days.first(where: { dayLabel($0) == selectedDay }), !isFuture(day), day.seconds > 0 else {
            return nil
        }
        return day
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let day = hoveredDay {
                Text("Coding time · \(RecapText.dayDate(day.date, calendar: controller.calendar))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(RecapText.duration(day.seconds))
                    .font(.system(size: 30, weight: .semibold))
                Text(RecapText.dayDetail(projects: day.projects.count, seconds: day.seconds, average: controller.pace.average))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                weekHeader
            }
        }
    }

    private var weekHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.isCurrentWeek ? "Coding time · so far" : "Coding time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if summary.seconds > 0 {
                Text(RecapText.duration(summary.seconds))
                    .font(.system(size: 30, weight: .semibold))
                Text([RecapText.comparison(controller.pace.change), RecapText.perDay(controller.pace.average)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Claude Code work this week.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            if !controller.isHooksConnected {
                HStack(spacing: 4) {
                    Text("Coding time is counted while session hooks are connected.")
                    Button("Settings…") {
                        openSettings()
                        NSApp.activate()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Chart (§3.3)

    private var chart: some View {
        let hours = summary.days.map { $0.seconds / 3600 }
        let top = max(hours.max() ?? 0, controller.pace.average / 3600, 1)
        return Chart {
            ForEach(summary.days, id: \.date) { day in
                let label = dayLabel(day)
                if isFuture(day) {
                    BarMark(x: .value("Day", label), y: .value("Hours", top), width: .ratio(0.8))
                        .foregroundStyle(Color.gray.opacity(0.08))
                } else {
                    // While a day is hovered, the other days step back.
                    let isDimmed = hoveredDay.map { $0.date != day.date } ?? false
                    ForEach(RecapPalette.stack(day, in: summary), id: \.name) { part in
                        BarMark(x: .value("Day", label), y: .value("Hours", part.seconds / 3600), width: .ratio(0.8))
                            .foregroundStyle(RecapPalette.color(RecapPalette.slot(of: part.name, in: summary)))
                            .opacity(isDimmed ? 0.35 : 1)
                    }
                }
            }
            if summary.seconds > 0 {
                RuleMark(y: .value("Average", controller.pace.average / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.green)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg").font(.caption2).foregroundStyle(.green)
                    }
            }
            if let day = hoveredDay {
                RuleMark(x: .value("Day", dayLabel(day)))
                    .foregroundStyle(.clear)
                    // Past the bar's edge (the rule is at its center), inside the plot, so it never covers the header's day total.
                    .annotation(position: .trailing, alignment: .top, spacing: 28, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(day)
                    }
            }
        }
        // Every weekday keeps its column, also a past day without work.
        .chartXScale(domain: summary.days.map(dayLabel))
        .chartXSelection(value: $selectedDay)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(RecapText.axisHours(hours)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    let label = value.as(String.self) ?? ""
                    Text(label.prefix(1))
                        .font(.caption2)
                        .fontWeight(isToday(label) ? .bold : .regular)
                }
            }
        }
        .frame(height: 120)
    }

    private func tooltip(_ day: RecapDaySplit) -> some View {
        // The day's total is in the header meanwhile; the tooltip lists its projects.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RecapPalette.stack(day, in: summary), id: \.name) { part in
                HStack(spacing: 4) {
                    Circle().fill(RecapPalette.color(RecapPalette.slot(of: part.name, in: summary))).frame(width: 6, height: 6)
                    Text(part.name)
                    Spacer(minLength: 8)
                    Text(RecapText.duration(part.seconds)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func dayLabel(_ day: RecapDaySplit) -> String {
        RecapText.dayName(day.date, calendar: controller.calendar)
    }

    private func isFuture(_ day: RecapDaySplit) -> Bool {
        day.date > controller.today
    }

    private func isToday(_ label: String) -> Bool {
        controller.isCurrentWeek && label == RecapText.dayName(controller.today, calendar: controller.calendar)
    }

    // MARK: Lists (§3.4)

    private var mostWorkedOn: some View {
        let first = max(summary.projects.first?.seconds ?? 1, 1)
        return section("Most worked on") {
            ForEach(Array(summary.projects.enumerated()), id: \.element.name) { index, project in
                if index > 0 {
                    Divider()
                }
                let color = RecapPalette.color(RecapPalette.slot(of: project.name, in: summary))
                let isSelected = project.name == filter?.name
                HStack(spacing: 8) {
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(RecapPalette.color(RecapPalette.slot(of: project.name, in: summary)))
                            .frame(width: max(4, proxy.size.width * project.seconds / first), height: 5)
                            .frame(maxHeight: .infinity)
                    }
                    Text(RecapText.duration(project.seconds))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .frame(height: 17)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(rowBackground(color, isSelected: isSelected, isHovered: hoveredProject == project.name)))
                .padding(.horizontal, -6)
                .opacity(filter == nil || isSelected ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProject = isSelected ? nil : project.name
                }
                .onHover { hovering in
                    if hovering {
                        hoveredProject = project.name
                    } else if hoveredProject == project.name {
                        hoveredProject = nil
                    }
                }
                .pointerStyle(.link)
                .accessibilityAddTraits(.isButton)
                // Sessions, files and lines on hover keep the list as compact as Screen Time's.
                .help(RecapText.projectDetail(project))
            }
        }
    }

    /// Selected: the project's color; under the pointer: a light neutral fill, a little stronger on the selected row.
    private func rowBackground(_ color: Color, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return color.opacity(isHovered ? 0.26 : 0.18)
        }
        return isHovered ? Color.primary.opacity(0.07) : .clear
    }

    private var work: some View {
        section("Work", accessory: { filterChip }) {
            row("Sessions") { Text(RecapText.number(filter?.sessions ?? summary.sessions)) }
            Divider()
            row("Files") { Text(RecapText.number(filter?.files ?? summary.files)) }
            Divider()
            row("Lines") {
                HStack(spacing: 4) {
                    Text("+\(RecapText.number(filter?.added ?? summary.added))").foregroundStyle(.green)
                    Text("\u{2212}\(RecapText.number(filter?.removed ?? summary.removed))").foregroundStyle(.red)
                }
            }
            Divider()
            row("Commands · agents") {
                Text("\(RecapText.number(filter?.commands ?? summary.commands)) · \(RecapText.number(filter?.agents ?? summary.agents))")
            }
            // The longest stretch is kept one per day, not per project.
            if filter == nil, let longest = summary.longest {
                Divider()
                row("Longest") { Text("\(longest.project) · \(RecapText.duration(longest.seconds))") }
            }
        }
    }

    private var limits: some View {
        section("Limits") {
            ForEach(Array(summary.accounts.enumerated()), id: \.element.name) { index, account in
                if index > 0 {
                    Divider()
                }
                row(account.name, color: .purple) {
                    HStack(spacing: 6) {
                        Text("5h hit \(account.hits)×").foregroundStyle(.secondary)
                        Text("7d peak \(Int(account.weeklyPeak.rounded()))%")
                            .foregroundStyle(RecapPalette.peakColor(account.weeklyPeak, thresholds: controller.thresholds))
                    }
                }
            }
        }
    }

    /// The selected project as a chip after the Work title; × shows all projects again.
    @ViewBuilder
    private var filterChip: some View {
        if let filter {
            HStack(spacing: 4) {
                Circle()
                    .fill(RecapPalette.color(RecapPalette.slot(of: filter.name, in: summary)))
                    .frame(width: 6, height: 6)
                Text(filter.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    selectedProject = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Show all projects")
                .accessibilityLabel("Show all projects")
            }
            .font(.caption)
            .padding(.leading, 7)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }

    /// A small muted title over its rows, as in Screen Time.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                accessory()
            }
            .frame(height: 18)
            .padding(.bottom, 2)
            content()
        }
        .padding(.top, 14)
    }

    /// A compact list row: the title on the left, its value on the right.
    private func row<Value: View>(_ title: String, color: Color = .primary, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(title).foregroundStyle(color)
            Spacer(minLength: 12)
            value().monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}
