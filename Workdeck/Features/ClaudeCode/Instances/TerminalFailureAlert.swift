import AppKit
import SwiftUI

extension View {
    /// Offers the command Terminal could not run.
    func terminalFailureAlert(_ command: Binding<String?>) -> some View {
        alert(
            "Couldn’t open Terminal",
            isPresented: Binding(get: { command.wrappedValue != nil }, set: { if !$0 { command.wrappedValue = nil } }),
            presenting: command.wrappedValue
        ) { value in
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: { value in
            Text("Run this in a terminal:\n\(value)")
        }
    }
}
