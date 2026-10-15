import SwiftUI

/// Settings for every agent in the notch (Codex spec §3.4).
struct NotchSettingsSection: View {
    @Bindable var settings: NotchSettings
    /// An agent is on, so the notch can show alerts.
    let isNotchEnabled: Bool
    let onChange: () -> Void
    /// Follows screen changes while Settings is open, e.g. the lid opening.
    @State private var hasCameraHousing = NotchPresenter.hasCameraHousingScreen()

    var body: some View {
        Section {
            Picker("Show", selection: $settings.mode) {
                ForEach(LimitsDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if !hasCameraHousing {
                Picker("Without a notch", selection: $settings.notchlessDisplay) {
                    ForEach(NotchlessDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }
            }
            Picker("First alert at", selection: $settings.firstThreshold) {
                ForEach(NotchSettings.firstThresholdOptions, id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Picker("Second alert at", selection: $settings.secondThreshold) {
                ForEach(NotchSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
            Toggle("Forecast when limits run out", isOn: $settings.showForecast)
            Group {
                Toggle("Notify when a session finishes", isOn: $settings.notifyWhenFinished)
                if settings.notifyWhenFinished {
                    Picker("After working for", selection: $settings.finishedAfterMinutes) {
                        ForEach(NotchSettings.finishedAfterOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }
                Toggle("Notify when a session needs you", isOn: $settings.notifyWhenNeedsYou)
            }
            // Alerts appear in the notch, which only shows while a tool is on.
            .disabled(!isNotchEnabled)
            Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            Text("On a Force Touch trackpad, when the notch opens under the pointer and on alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Keep Mac awake while an agent works", isOn: $settings.keepAwakeWhileWorking)
            if !isNotchEnabled {
                Text("Turn on Claude Code or Codex in the menu bar popover to see the notch and its alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("Notch", symbol: "menubar.rectangle", color: .teal)
        } footer: {
            Text("Applies to Claude Code and Codex. Keeping the Mac awake uses a standard power assertion; the display still sleeps, and a closed lid still sleeps unless Closed-Lid Mode is on.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.mode) { onChange() }
        .onChange(of: settings.firstThreshold) { onChange() }
        .onChange(of: settings.secondThreshold) { onChange() }
        .onChange(of: settings.showForecast) { onChange() }
        .onChange(of: settings.notchlessDisplay) { onChange() }
        .onChange(of: settings.keepAwakeWhileWorking) { onChange() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasCameraHousing = NotchPresenter.hasCameraHousingScreen()
        }
    }
}
