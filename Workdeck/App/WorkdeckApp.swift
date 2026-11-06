import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, codex: appDelegate.codex, notes: appDelegate.notes, recap: appDelegate.recap, demo: appDelegate.demo, updates: appDelegate.updates)
        } label: {
            MenuBarLabel(lidSleep: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, instances: appDelegate.instances, codex: appDelegate.codex, notes: appDelegate.notes, notesShortcuts: appDelegate.notesShortcuts, demo: appDelegate.demo, updates: appDelegate.updates, feedback: appDelegate.feedback)
        }

        Window("Claude Code Chats", id: ChatsWindow.id) {
            ChatsWindow(controller: appDelegate.chats)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Instances", id: InstancesWindow.id) {
            InstancesWindow(controller: appDelegate.instancesCompare)
        }
        .defaultSize(width: 900, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Statistics", id: StatisticsWindow.id) {
            StatisticsWindow(controller: appDelegate.recap.statistics)
        }
        .defaultSize(width: 460, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Release Notes", id: ReleaseNotesWindow.id) {
            ReleaseNotesWindow(updates: appDelegate.updates)
        }
        .defaultSize(width: 560, height: 420)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
