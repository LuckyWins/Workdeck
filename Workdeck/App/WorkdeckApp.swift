import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        } label: {
            MenuBarLabel(lidSleep: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        }
    }
}
