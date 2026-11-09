import Observation
import SwiftUI

/// The tab the quick notes panel shows. Kept in an observable so a switch is a state change inside `withAnimation`:
/// replacing the hosting view's root view did not animate reliably.
@Observable
final class PanelTabState {
    var tab: NotchTab = .notes
    /// What the panel showed when it started closing: drawn while it draws back into the notch, whatever the resets
    /// of closing did meanwhile (notes polish spec §5). Nil while open.
    var closingLook: PanelLook?
}

/// The tab and the note's mode the panel showed: frozen for the closing animation.
struct PanelLook: Equatable {
    var tab: NotchTab
    var mode: PanelMode
}

/// The panel's root view: `NotesPanelView` on the observed tab.
struct NotesPanelHost: View {
    let state: PanelTabState
    let model: NotesPanelModel
    let notchModel: LimitsNotchModel?
    let topInset: CGFloat
    let closedSize: CGSize
    let opening: Int
    let grows: Bool
    let onSelectTab: (NotchTab) -> Void
    let onHover: (Bool) -> Void
    let onSize: (CGSize) -> Void
    let onMorph: () -> Void

    var body: some View {
        NotesPanelView(
            model: model, notchModel: notchModel, tab: state.closingLook?.tab ?? state.tab, topInset: topInset,
            opening: opening, grows: grows, frozenMode: state.closingLook?.mode, isClosing: state.closingLook != nil,
            closedSize: closedSize,
            onSelectTab: onSelectTab, onHover: onHover, onSize: onSize, onMorph: onMorph
        )
    }
}
