import AppKit
import SwiftUI

/// The small notch message after ↩ or ⌘↩, in the notch alerts' style but neutral: a gray badge, no colored wash
/// (quick notes spec §3.4). A command Terminal could not run is offered for copying (§5.4).
struct NotesConfirmationView: View {
    let model: NotesPanelModel
    let confirmation: NotesConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: confirmation.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Terminal.text)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                if let mark = confirmation.mark {
                    AgentIcon(agent: mark.kind, size: 13)
                }
                Text(confirmation.title)
                    .font(Terminal.font(13, weight: .semibold))
                    .lineLimit(1)
            }
            if !confirmation.subtitle.isEmpty {
                Text(confirmation.subtitle)
                    .font(Terminal.font(12))
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(2)
                    .padding(.leading, 30)
            }
            if model.confirmationStays, model.failedCommand != nil {
                HStack(spacing: 8) {
                    Button("Copy Command") {
                        model.copyFailedCommand()
                    }
                    Button("OK") {
                        model.finishConfirmation()
                    }
                }
                .controlSize(.small)
                .padding(.leading, 30)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(Terminal.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
