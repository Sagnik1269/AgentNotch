import SwiftUI

/// Content shown when the notch is open: a header row beside the camera housing, then the active tab.
struct ExpandedNotchView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            header
                .frame(height: max(vm.notchSize.height, 28))

            Group {
                switch vm.selectedTab {
                case .home: HomeTabView()
                case .media: MediaTabView()
                case .shelf: ShelfTabView()
                case .dev: DevTabView(onOpenSettings: { vm.onOpenSettings?() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(vm.selectedTab)
            .transition(.opacity)
        }
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }

    /// Tabs on the left and actions on the right; the middle stays empty for the camera housing.
    private var header: some View {
        HStack(spacing: 4) {
            ForEach(NotchTab.allCases) { tab in
                TabButton(tab: tab, isSelected: vm.selectedTab == tab) {
                    withAnimation(.easeInOut(duration: 0.15)) { vm.selectedTab = tab }
                }
            }
            Spacer(minLength: vm.notchSize.width + 20)
            HeaderIconButton(systemName: "gearshape.fill", help: "Settings") {
                vm.onOpenSettings?()
            }
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 22)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(hovering ? 0.8 : 0.5))
                .background(
                    Capsule().fill(Color.white.opacity(isSelected ? 0.18 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.55))
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
