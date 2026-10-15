import Foundation
import OSLog
import Observation

/// The weekly recap and the Statistics window for every agent (Codex recap spec §5): records what each agent tool
/// reports on every notch refresh, keeps `recap.json`, shows last week's card and opens Statistics.
@Observable
final class RecapController {
    /// The Statistics window's state, fed the recorder's days on every refresh (statistics spec §3.5).
    let statistics: StatisticsController
    /// Opens the Statistics window (the app hands it `WindowOpener`).
    @ObservationIgnored var onOpenStatistics: (() -> Void)?

    @ObservationIgnored private let composer: NotchComposer
    @ObservationIgnored private let settings: RecapSettings
    @ObservationIgnored private let store: RecapStore?
    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var recorder: RecapRecorder?
    /// Last week's recap, shown until dismissed (recap spec §3.2).
    @ObservationIgnored private var pendingRecap: WeeklyRecapSummary?
    @ObservationIgnored private var lastSave: Date?
    @ObservationIgnored private var connectedAgents: Set<AgentKind> = []
    /// Demo mode: the script replaces the card and Statistics (demo mode spec §2.3).
    @ObservationIgnored private(set) var isDemoActive = false
    @ObservationIgnored private var demoDays: [RecapDay] = []
    /// The demo's card while it is up.
    @ObservationIgnored private var demoRecap: WeeklyRecapSummary?
    /// A real card was expanded when the demo started; at stop it expands again, otherwise only its mark returns.
    @ObservationIgnored private var realRecapWasExpanded = false

    init(
        composer: NotchComposer,
        settings: RecapSettings,
        store: RecapStore?,
        activity: any SessionActivityMonitoring,
        calendar: Calendar = RecapCalendar.calendar(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.composer = composer
        self.settings = settings
        self.store = store
        self.activity = activity
        self.calendar = calendar
        self.clock = clock
        statistics = StatisticsController(calendar: calendar, clock: clock)
    }

    /// After the agent tools started: they report from their first refresh on.
    func start() {
        if let store {
            recorder = RecapRecorder(days: store.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        composer.onRefresh = { [weak self] in self?.record() }
        composer.onRecapDismiss = { [weak self] in self?.dismissRecap() }
        composer.onRecapDetails = { [weak self] in self?.openRecapDetails() }
        // The first unlock of a week shows last week's card (recap spec §3.1).
        activity.onChange = { [weak self] active in
            if active {
                self?.checkRecap()
            }
        }
        activity.start()
        record(saving: false)
        checkRecap()
    }

    /// Shows last week's recap if it is due: not dismissed, worth showing, an agent on and a notch to show it in.
    func checkRecap() {
        guard let recorder, composer.isAnyAgentEnabled, composer.hasNotchScreen,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: RecapCalendar.weekStart(of: clock(), calendar: calendar))
        else { return }
        // A recap left open gives way to the next week's, or goes when the next week has none.
        if let pending = pendingRecap {
            guard pending.weekStart != lastWeek else { return }
            pendingRecap = nil
            composer.recapKeepsVisible = false
            if !isDemoActive {
                composer.presenter.showRecap(nil)
            }
            composer.refresh()
        }
        let key = RecapCalendar.dayKey(lastWeek, calendar: calendar)
        guard settings.dismissedWeek != key else { return }
        let summary = WeeklyRecap.summary(days: recorder.days, weekStart: lastWeek, calendar: calendar)
        guard summary.isWorthShowing else {
            settings.dismissedWeek = key
            return
        }
        pendingRecap = summary
        composer.recapKeepsVisible = true
        if !isDemoActive {
            composer.presenter.showRecap(summary)
        }
        composer.refresh()
    }

    func dismissRecap() {
        if isDemoActive {
            // The demo's card is made up: closing it keeps nothing (demo mode spec §2.3).
            guard demoRecap != nil else { return }
            demoRecap = nil
            composer.presenter.showRecap(nil)
            return
        }
        guard let recap = pendingRecap else { return }
        settings.dismissedWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        composer.recapKeepsVisible = false
        composer.presenter.showRecap(nil)
        composer.refresh()
    }

    /// Shows the week holding `week` (`nil`: the current week) in the Statistics window (statistics spec §2).
    func openStatistics(week: Date?) {
        statistics.setAgent(nil)
        statistics.show(week: week)
        onOpenStatistics?()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    func openRecapDetails() {
        let week = isDemoActive ? demoRecap?.weekStart : pendingRecap?.weekStart
        dismissRecap()
        openStatistics(week: week)
    }

    /// Every agent's sessions and limits into the day's totals; saved at most once a minute.
    func record() {
        record(saving: true)
    }

    /// On quit: keeps the time and stretches up to now, then writes.
    func save() {
        guard let recorder else { return }
        record(saving: false)
        recorder.finish(now: clock())
        write()
    }

    private func record(saving: Bool) {
        let samples = composer.recapSamples
        connectedAgents = Set(samples.filter(\.isConnected).map(\.agent))
        if let recorder {
            let now = clock()
            recorder.record(samples: samples, now: now)
            // Only when something changed.
            if saving, recorder.hasChanges, lastSave.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                write()
            }
        }
        updateStatistics()
    }

    private func write() {
        guard let recorder, let store else { return }
        let now = clock()
        lastSave = now
        do {
            try store.save(recorder.days, now: now, calendar: calendar)
            recorder.markSaved()
        } catch {
            WorkdeckLog.sessions.error("Recap: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateStatistics() {
        statistics.update(
            days: isDemoActive ? demoDays : recorder?.days ?? [],
            connectedAgents: isDemoActive ? Set(AgentKind.allCases) : connectedAgents,
            thresholds: composer.settings.thresholds
        )
    }
}

extension RecapController: DemoParticipant {
    var demoLength: TimeInterval {
        RecapDemoScript.length
    }

    func demoDidStart() {
        isDemoActive = true
        demoDays = RecapDemoScript.days(now: clock(), calendar: calendar)
        // A real card steps aside and comes back at stop.
        realRecapWasExpanded = pendingRecap != nil && composer.presenter.isRecapExpanded
        if pendingRecap != nil {
            composer.presenter.showRecap(nil)
        }
        updateStatistics()
    }

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        guard RecapDemoScript.showsRecap(after: previous, upTo: elapsed) else { return }
        let recap = RecapDemoScript.recap(now: clock(), calendar: calendar)
        demoRecap = recap
        composer.presenter.showRecap(recap, for: .seconds(RecapDemoScript.recapSeconds))
    }

    func demoDidStop() {
        isDemoActive = false
        demoDays = []
        if demoRecap != nil || pendingRecap != nil {
            demoRecap = nil
            composer.presenter.showRecap(pendingRecap, for: realRecapWasExpanded ? nil : .zero)
        }
        updateStatistics()
    }
}
