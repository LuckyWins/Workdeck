import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, codex: appDelegate.codex, recap: appDelegate.recap, demo: appDelegate.demo)
        } label: {
            MenuBarLabel(lidSleep: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, instances: appDelegate.instances, codex: appDelegate.codex, demo: appDelegate.demo)
        }

        Window("Claude Code Chats", id: ChatsWindow.id) {
            ChatsWindow(controller: appDelegate.chats)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Statistics", id: StatisticsWindow.id) {
            StatisticsWindow(controller: appDelegate.recap.statistics)
        }
        .defaultSize(width: 460, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
