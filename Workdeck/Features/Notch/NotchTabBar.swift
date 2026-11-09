import SwiftUI

/// The bar at the top of the expanded notch (notch tabs spec §2, mockup B): the tabs' icons on the left, the
/// selected one on a rounded gray background, its name dim on the right.
struct NotchTabBar: View {
    let selected: NotchTab
    let onSelect: (NotchTab) -> Void
    @State private var hovered: NotchTab?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NotchTab.allCases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(tab == selected || tab == hovered ? Color.white : Terminal.dim)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(tab == selected ? 0.14 : tab == hovered ? 0.07 : 0))
                        }
                        .contentShape(Rectangle())
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
            }
            Spacer(minLength: 8)
            Text(selected.title)
                .font(.system(size: 11))
                .foregroundStyle(Terminal.dim)
        }
    }
}
