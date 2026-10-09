import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode)
        } label: {
            MenuBarLabel(lidSleep: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, instances: appDelegate.instances)
        }

        Window("Claude Code Chats", id: ChatsWindow.id) {
            ChatsWindow(controller: appDelegate.chats)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
