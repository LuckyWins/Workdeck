import Foundation

/// One square of the activity grid (activity grid spec §2.2–§2.4).
nonisolated struct ActivityDay: Equatable, Sendable {
    /// Midnight of the day.
    var date: Date
    /// Coding time for the grid's agent filter; 0 for days after today.
    var seconds: Double
    /// 0...4 (`ActivityGrid.level(seconds:)`).
    var level: Int
    var isFuture: Bool
    /// The day's top three projects for the tooltip: most time first, ties by name, only those with time.
    var projects: [RecapProjectTime]
}

/// One column: a Monday-to-Sunday week.
nonisolated struct ActivityWeek: Equatable, Sendable {
    /// Monday 00:00.
    var start: Date
    /// Seven days, Monday first.
    var days: [ActivityDay]
}

/// A month's short name above the column where it starts.
nonisolated struct ActivityMonthLabel: Equatable, Sendable {
    var column: Int
    var name: String
}

/// The kept weeks as a GitHub-style grid of days, with the streak and active days (activity grid spec §2). Pure.
nonisolated struct ActivityGrid: Equatable, Sendable {
    /// Oldest first; the current week last (`RecapStore.keptWeeks + 1` columns).
    var weeks: [ActivityWeek]
    var months: [ActivityMonthLabel]
    var streak: Int
    var activeDays: Int

    /// Upper bounds of levels 1, 2 and 3 in seconds: under 1h, under 3h, under 6h (spec §2.3).
    static let thresholds: [Double] = [3600, 3 * 3600, 6 * 3600]
    /// Labels closer than this to the next one are left out (spec §2.2).
    static let monthLabelSpacing = 3
    static let projectsShown = 3

    static func level(seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return 1 + thresholds.filter { seconds >= $0 }.count
    }

    static func make(days: [RecapDay], agent: AgentKind?, now: Date, calendar: Calendar) -> ActivityGrid {
        let today = calendar.startOfDay(for: now)
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        func seconds(_ date: Date) -> Double {
            byKey[RecapCalendar.dayKey(date, calendar: calendar)]?.seconds(for: agent) ?? 0
        }

        let thisWeek = RecapCalendar.weekStart(of: now, calendar: calendar)
        let first = calendar.date(byAdding: .weekOfYear, value: -RecapStore.keptWeeks, to: thisWeek) ?? thisWeek
        var weeks: [ActivityWeek] = []
        for column in 0...RecapStore.keptWeeks {
            guard let start = calendar.date(byAdding: .weekOfYear, value: column, to: first) else { continue }
            let week = (0..<7).compactMap { offset -> ActivityDay? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
                guard date <= today else {
                    return ActivityDay(date: date, seconds: 0, level: 0, isFuture: true, projects: [])
                }
                // One key per day: this runs on every hook event while the window is open.
                let day = byKey[RecapCalendar.dayKey(date, calendar: calendar)]
                let time = day?.seconds(for: agent) ?? 0
                let projects = day.map { topProjects(of: $0, agent: agent) } ?? []
                return ActivityDay(date: date, seconds: time, level: level(seconds: time), isFuture: false, projects: projects)
            }
            weeks.append(ActivityWeek(start: start, days: week))
        }

        let activeDays = weeks.flatMap(\.days).filter { !$0.isFuture && $0.seconds > 0 }.count
        return ActivityGrid(
            weeks: weeks,
            months: monthLabels(weeks, calendar: calendar),
            streak: streak(today: today, first: first, calendar: calendar, seconds: seconds),
            activeDays: activeDays
        )
    }

    private static func topProjects(of day: RecapDay, agent: AgentKind?) -> [RecapProjectTime] {
        day.projects(for: agent)
            .map { RecapProjectTime(name: $0.key, seconds: $0.value.seconds) }
            .filter { $0.seconds > 0 }
            .sorted { ($1.seconds, $0.name) < ($0.seconds, $1.name) }
            .prefix(projectsShown)
            .map { $0 }
    }

    private static func monthLabels(_ weeks: [ActivityWeek], calendar: Calendar) -> [ActivityMonthLabel] {
        var labels: [ActivityMonthLabel] = []
        var previousMonth: Int?
        for (column, week) in weeks.enumerated() {
            let month = calendar.component(.month, from: week.start)
            if month != previousMonth {
                labels.append(ActivityMonthLabel(column: column, name: RecapText.monthName(week.start, calendar: calendar)))
                previousMonth = month
            }
        }
        // Only the first column's label can sit closer than a month to the next: drop it, as GitHub does.
        if labels.count > 1, labels[1].column - labels[0].column < monthLabelSpacing {
            labels.removeFirst()
        }
        return labels
    }

    /// Consecutive active days ending today, or yesterday while today has no time yet; never before the grid.
    private static func streak(today: Date, first: Date, calendar: Calendar, seconds: (Date) -> Double) -> Int {
        var day = today
        if seconds(day) <= 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
            day = yesterday
        }
        var count = 0
        while day >= first, seconds(day) > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
