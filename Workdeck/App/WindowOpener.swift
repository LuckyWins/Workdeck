import AppKit
import SwiftUI

/// Opens SwiftUI windows from code outside views (a notch alert click); the menu bar label hands it the action.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()

    var openWindow: OpenWindowAction?

    func open(_ id: String) {
        openWindow?(id: id)
        NSApp.activate()
    }
}
