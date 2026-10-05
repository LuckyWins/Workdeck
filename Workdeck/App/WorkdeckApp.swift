import SwiftUI

@main
struct WorkdeckApp: App {
    var body: some Scene {
        MenuBarExtra("Workdeck", systemImage: "rectangle.stack") {
            Text("Workdeck")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
