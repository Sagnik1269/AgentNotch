import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, media, shelf, dev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .media: "Media"
        case .shelf: "Shelf"
        case .dev: "Dev"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .media: "music.note"
        case .shelf: "tray.full.fill"
        case .dev: "terminal.fill"
        }
    }
}

/// UI state for one screen's notch.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var isHovering = false
    @Published var selectedTab: NotchTab = .home

    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    // Shape geometry. Top radius is the outward "ear" flare where the shape meets the screen edge.
    let closedTopRadius: CGFloat = 6
    let closedBottomRadius: CGFloat
    let openTopRadius: CGFloat = 14
    let openBottomRadius: CGFloat = 26
    let openContentSize = CGSize(width: 600, height: 210)

    var onRequestOpen: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(notchSize: CGSize, hasPhysicalNotch: Bool) {
        self.notchSize = notchSize
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedBottomRadius = hasPhysicalNotch ? 10 : notchSize.height / 2
    }

    // Closed live-activity geometry: "wings" extend the notch sideways to hold content
    // left and right of the camera housing; a peek row grows it downward.
    var mediaWingWidth: CGFloat { max(notchSize.height, 24) + 10 }
    let hudWingWidth: CGFloat = 92
    /// Gap between the HUD's outer edges and its icon (left) / slider (right); equal on both sides.
    let hudEdgeInset: CGFloat = 14
    let peekRowHeight: CGFloat = 34
    let peekMinWidth: CGFloat = 380
    let lyricRowHeight: CGFloat = 36
    let lyricRowWidth: CGFloat = 460
    let alertRowHeight: CGFloat = 40
    let alertMinWidth: CGFloat = 440

    func closedShapeSize(for activity: ClosedActivity) -> CGSize {
        let base = notchSize.width + closedTopRadius * 2
        switch activity {
        case .idle:
            return CGSize(width: base, height: notchSize.height)
        case .hud:
            return CGSize(width: base + hudWingWidth * 2, height: notchSize.height)
        case .nowPlaying(let row):
            let width = base + mediaWingWidth * 2
            switch row {
            case .none:
                return CGSize(width: width, height: notchSize.height)
            case .peek:
                return CGSize(width: max(width, peekMinWidth), height: notchSize.height + peekRowHeight)
            case .lyric:
                return CGSize(width: max(width, lyricRowWidth), height: notchSize.height + lyricRowHeight)
            }
        case .alert:
            return CGSize(width: max(base + mediaWingWidth * 2, alertMinWidth),
                          height: notchSize.height + alertRowHeight)
        case .agents:
            return CGSize(width: base + mediaWingWidth * 2, height: notchSize.height)
        }
    }

    var openShapeSize: CGSize {
        CGSize(width: openContentSize.width + openTopRadius * 2, height: openContentSize.height)
    }

    func shapeSize(for activity: ClosedActivity) -> CGSize {
        isOpen ? openShapeSize : closedShapeSize(for: activity)
    }

    var topRadius: CGFloat { isOpen ? openTopRadius : closedTopRadius }

    func bottomRadius(for activity: ClosedActivity) -> CGFloat {
        if isOpen { return openBottomRadius }
        if case .nowPlaying(row: .peek) = activity { return 18 }
        if case .nowPlaying(row: .lyric) = activity { return 18 }
        if case .alert = activity { return 20 }
        return closedBottomRadius
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
    }
}
