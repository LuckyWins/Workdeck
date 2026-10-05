import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep)
        } label: {
            Image(systemName: appDelegate.lidSleep.isActive ? "rectangle.stack.fill" : "rectangle.stack")
                .accessibilityLabel("Workdeck")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep)
        }
    }
}
