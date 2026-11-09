import Observation
import SwiftUI

/// The tab the quick notes panel shows. Kept in an observable so a switch is a state change inside `withAnimation`:
/// replacing the hosting view's root view did not animate reliably.
@Observable
final class PanelTabState {
    var tab: NotchTab = .notes
}

/// The panel's root view: `NotesPanelView` on the observed tab.
struct NotesPanelHost: View {
    let state: PanelTabState
    let model: NotesPanelModel
    let notchModel: LimitsNotchModel?
    let topInset: CGFloat
    let opening: Int
    let grows: Bool
    let onSelectTab: (NotchTab) -> Void
    let onHover: (Bool) -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        NotesPanelView(
            model: model, notchModel: notchModel, tab: state.tab, topInset: topInset, opening: opening, grows: grows,
            onSelectTab: onSelectTab, onHover: onHover, onSize: onSize
        )
    }
}
