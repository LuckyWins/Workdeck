import SwiftUI

/// The Claude Code Chats window (spec §3.2).
struct ChatsWindow: View {
    static let id = "claude-chats"

    var body: some View {
        Text("No chats yet.")
            .frame(minWidth: 520, minHeight: 360)
    }
}
