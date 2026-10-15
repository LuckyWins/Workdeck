import Foundation
import Observation

/// The Statistics window's week and its numbers, rebuilt from the recorder's days (statistics spec §3).
@Observable
final class StatisticsController {
    let calendar: Calendar
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var days: [RecapDay] = []
    /// On "This week": moves with the calendar when a new week starts (spec §6).
    @ObservationIgnored private var followsCurrentWeek = true
    /// How often the shown numbers changed; lets tests see that an unchanged update republishes nothing.
    @ObservationIgnored private(set) var publishCount = 0
    /// Whether the window is on screen; while it is closed, updates only keep the days.
    @ObservationIgnored var isVisible = false {
        didSet {
            if isVisible, !oldValue {
                rebuild()
            }
        }
    }

    private(set) var weekStart: Date
    private(set) var summary: WeeklyRecapSummary
    private(set) var pace = RecapPace(elapsedDays: 1, average: 0, change: nil)
    /// Midnight of today: changes once a day, not on every update, so the window does not re-render for the clock.
    private(set) var today: Date
    private(set) var isCurrentWeek = true
    private(set) var canGoBack = false
    private(set) var isHooksConnected = true
    private(set) var thresholds: [Int] = []
    /// `nil` shows every agent (Codex recap spec §3.2).
    private(set) var agent: AgentKind?
    /// Two agents have time in the kept days: the window offers the filter.
    private(set) var showsAgentFilter = false
    @ObservationIgnored private var connectedAgents: Set<AgentKind> = []

    init(calendar: Calendar, clock: @escaping () -> Date) {
        self.calendar = calendar
        self.clock = clock
        let now = clock()
        today = calendar.startOfDay(for: now)
        let weekStart = RecapCalendar.weekStart(of: now, calendar: calendar)
        self.weekStart = weekStart
        summary = WeeklyRecapSummary(weekStart: weekStart)
        rebuild()
    }

    var canGoForward: Bool {
        !isCurrentWeek
    }

    func update(days: [RecapDay], connectedAgents: Set<AgentKind>, thresholds: [Int]) {
        self.days = days
        self.connectedAgents = connectedAgents
        set(\.isHooksConnected, hooksConnected)
        set(\.thresholds, thresholds)
        // `refresh()` runs on every hook event; a closed window catches up when it opens.
        guard isVisible else { return }
        rebuild()
    }

    /// Shows one agent's own work, or (`nil`) every agent's.
    func setAgent(_ agent: AgentKind?) {
        set(\.agent, agent)
        set(\.isHooksConnected, hooksConnected)
        rebuild()
    }

    /// The hooks line shows when no agent counts, or when the filtered agent does not.
    private var hooksConnected: Bool {
        agent.map { connectedAgents.contains($0) } ?? !connectedAgents.isEmpty
    }

    /// Shows the week holding `week`; `nil` shows the current week and follows it.
    func show(week: Date?) {
        let current = RecapCalendar.weekStart(of: clock(), calendar: calendar)
        let start = week.map { RecapCalendar.weekStart(of: $0, calendar: calendar) } ?? current
        followsCurrentWeek = start == current
        set(\.weekStart, start)
        rebuild()
    }

    func goBack() {
        guard canGoBack, let start = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) else { return }
        show(week: start)
    }

    func goForward() {
        guard canGoForward, let start = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return }
        show(week: start)
    }

    func showCurrentWeek() {
        show(week: nil)
    }

    private func rebuild() {
        let now = clock()
        let current = RecapCalendar.weekStart(of: now, calendar: calendar)
        if followsCurrentWeek {
            set(\.weekStart, current)
        }
        set(\.today, calendar.startOfDay(for: now))
        set(\.isCurrentWeek, weekStart == current)
        set(\.canGoBack, weekStart > oldestWeek(current: current))
        set(\.showsAgentFilter, AgentKind.allCases.filter { kind in days.contains { $0.seconds(for: kind) > 0 } }.count > 1)
        // Without the control there is no way back from a filter: show every agent.
        if !showsAgentFilter, agent != nil {
            set(\.agent, nil)
            set(\.isHooksConnected, hooksConnected)
        }
        set(\.summary, WeeklyRecap.summary(days: days, weekStart: weekStart, calendar: calendar, agent: agent))
        set(\.pace, WeeklyRecap.pace(days: days, weekStart: weekStart, now: now, calendar: calendar, agent: agent))
    }

    /// The oldest week with a day, but never more than the store keeps (spec §3.1).
    private func oldestWeek(current: Date) -> Date {
        let limit = calendar.date(byAdding: .weekOfYear, value: -RecapStore.keptWeeks, to: current) ?? current
        let oldestDay = days.compactMap { RecapCalendar.date(ofKey: $0.date, calendar: calendar) }.min()
        let oldest = oldestDay.map { RecapCalendar.weekStart(of: $0, calendar: calendar) } ?? current
        return min(current, max(limit, oldest))
    }

    /// Assigns only changes: `refresh()` runs on every hook event, and each assignment re-renders the window.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<StatisticsController, Value>, _ value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        publishCount += 1
    }
}
