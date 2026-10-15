import Foundation
import Observation

@Observable
final class ClaudeCodeSettings {
    static let firstThresholdOptions = NotchSettings.firstThresholdOptions
    static let finishedAfterOptions = NotchSettings.finishedAfterOptions

    static func secondThresholdOptions(above first: Int) -> [Int] {
        NotchSettings.secondThresholdOptions(above: first)
    }

    static func normalizedFirst(_ value: Int) -> Int {
        NotchSettings.normalizedFirst(value)
    }

    static func normalizedSecond(_ value: Int, above first: Int) -> Int {
        NotchSettings.normalizedSecond(value, above: first)
    }

    private enum Keys {
        static let isEnabled = "claudeLimits.isEnabled"
        static let connectedAt = "claudeLimits.connectedAt"
        static let firedAlertKeys = "claudeLimits.firedAlertKeys"
        static let fetchFromAPI = "claudeLimits.fetchFromAPI"
        static let hookEventsVersion = "claudeSessions.hookEventsVersion"
        static let dismissedRecapWeek = "claudeRecap.dismissedWeek"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The settings every agent shares; Claude's code reads them through the forwarding properties below.
    @ObservationIgnored let notch: NotchSettings

    var mode: LimitsDisplayMode {
        get { notch.mode }
        set { notch.mode = newValue }
    }

    var firstThreshold: Int {
        get { notch.firstThreshold }
        set { notch.firstThreshold = newValue }
    }

    var secondThreshold: Int {
        get { notch.secondThreshold }
        set { notch.secondThreshold = newValue }
    }

    var notifyOnReset: Bool {
        get { notch.notifyOnReset }
        set { notch.notifyOnReset = newValue }
    }

    var showForecast: Bool {
        get { notch.showForecast }
        set { notch.showForecast = newValue }
    }

    var collapsesOtherAccounts: Bool {
        get { notch.collapsesOtherAccounts }
        set { notch.collapsesOtherAccounts = newValue }
    }

    var notchlessDisplay: NotchlessDisplay {
        get { notch.notchlessDisplay }
        set { notch.notchlessDisplay = newValue }
    }

    var keepAwakeWhileWorking: Bool {
        get { notch.keepAwakeWhileWorking }
        set { notch.keepAwakeWhileWorking = newValue }
    }

    var notifyWhenFinished: Bool {
        get { notch.notifyWhenFinished }
        set { notch.notifyWhenFinished = newValue }
    }

    var finishedAfterMinutes: Int {
        get { notch.finishedAfterMinutes }
        set { notch.finishedAfterMinutes = newValue }
    }

    var notifyWhenNeedsYou: Bool {
        get { notch.notifyWhenNeedsYou }
        set { notch.notifyWhenNeedsYou = newValue }
    }

    var thresholds: [Int] {
        notch.thresholds
    }

    /// The Monday ("2026-10-05") of the last week whose recap was dismissed or skipped (recap spec §3.2).
    var dismissedRecapWeek: String? {
        didSet { defaults.set(dismissedRecapWeek, forKey: Keys.dismissedRecapWeek) }
    }

    /// Whether the notch or menu bar indicator is shown.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    /// When Claude Code was connected; used to tell "waiting for data" from "no Pro/Max data".
    var connectedAt: Date? {
        didSet { defaults.set(connectedAt, forKey: Keys.connectedAt) }
    }

    /// Threshold alerts already shown, so relaunching does not repeat them.
    var firedAlertKeys: Set<String> {
        didSet { defaults.set(Array(firedAlertKeys).sorted(), forKey: Keys.firedAlertKeys) }
    }

    /// The main account keeps `claudeLimits.firedAlertKeys`; an extra one `claudeLimits.firedAlertKeys.<name>` (spec §3.4).
    func firedAlertKeys(for account: String?) -> Set<String> {
        guard let account else { return firedAlertKeys }
        return Set(defaults.stringArray(forKey: Keys.firedAlertKeys + "." + account) ?? [])
    }

    func setFiredAlertKeys(_ keys: Set<String>, for account: String?) {
        guard let account else {
            firedAlertKeys = keys
            return
        }
        let key = Keys.firedAlertKeys + "." + account
        if keys.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(keys).sorted(), forKey: key)
        }
    }

    /// Opt-in: poll Anthropic's undocumented usage endpoint with Claude Code's Keychain token.
    var fetchFromAPI: Bool {
        didSet { defaults.set(fetchFromAPI, forKey: Keys.fetchFromAPI) }
    }

    /// How many hook events this Mac's Workdeck last offered; newly added events are installed once.
    var hookEventsVersion: Int {
        didSet { defaults.set(hookEventsVersion, forKey: Keys.hookEventsVersion) }
    }

    init(defaults: UserDefaults = .standard, notch: NotchSettings? = nil) {
        self.defaults = defaults
        self.notch = notch ?? NotchSettings(defaults: defaults)
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        connectedAt = defaults.object(forKey: Keys.connectedAt) as? Date
        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
        fetchFromAPI = defaults.bool(forKey: Keys.fetchFromAPI)
        hookEventsVersion = defaults.integer(forKey: Keys.hookEventsVersion)
        dismissedRecapWeek = defaults.string(forKey: Keys.dismissedRecapWeek)
    }
}
