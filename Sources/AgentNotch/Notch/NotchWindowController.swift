import AppKit
import SwiftUI

/// Owns the panel, view model and mouse/hover logic for the notch on one screen.
@MainActor
final class NotchWindowController {
    let screen: NSScreen
    let viewModel: NotchViewModel
    private let panel: NotchPanel
    private let settings = AppSettings.shared

    private var pendingHoverWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var isHiddenForFullscreen = false

    /// Room around the open shape so its shadow isn't clipped by the window edge.
    private static let shadowPadding: CGFloat = 30

    init(screen: NSScreen, onOpenSettings: @escaping () -> Void) {
        self.screen = screen
        viewModel = NotchViewModel(notchSize: screen.notchSize, hasPhysicalNotch: screen.hasPhysicalNotch)

        let open = viewModel.openShapeSize
        let size = CGSize(width: open.width + Self.shadowPadding * 2, height: open.height + Self.shadowPadding)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel = NotchPanel(contentRect: frame)

        let host = NotchHostingView(rootView: NotchView(vm: viewModel))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setFrame(frame, display: true)

        viewModel.onRequestOpen = { [weak self] in self?.open() }
        viewModel.onRequestClose = { [weak self] in self?.close() }
        viewModel.onOpenSettings = { [weak self] in
            self?.close()
            onOpenSettings()
        }

        panel.orderFrontRegardless()
        updateFullscreenVisibility()
    }

    func tearDown() {
        pendingHoverWork?.cancel()
        stopPolling()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Open / close

    func open() {
        guard !viewModel.isOpen, !isHiddenForFullscreen else { return }
        pendingHoverWork?.cancel()
        // Opening on a dev alert or agent status jumps straight to the details.
        let activity = ClosedActivity.current()
        if activity.opensDevTab {
            viewModel.selectedTab = .dev
            if case .alert = activity { AlertCenter.shared.dismiss() }
        }
        if settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        viewModel.setOpen(true)
        panel.ignoresMouseEvents = false
        startPolling()
    }

    func close() {
        guard viewModel.isOpen else { return }
        pendingHoverWork?.cancel()
        viewModel.setOpen(false)
        handleMouseMoved(NSEvent.mouseLocation)
    }

    // MARK: - Mouse handling

    /// Screen-space rectangle that counts as "on the notch".
    private func hitRect() -> NSRect {
        let size = viewModel.shapeSize(for: .current())
        let f = screen.frame
        var rect = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height + 1)
        if !viewModel.isOpen {
            // A little slop makes the small closed notch easier to hit.
            rect = rect.insetBy(dx: -10, dy: 0)
            rect.origin.y -= 6
            rect.size.height += 6
        }
        return rect
    }

    func handleMouseMoved(_ point: NSPoint) {
        guard !isHiddenForFullscreen else { return }
        let inside = hitRect().contains(point)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        if inside || viewModel.isOpen { startPolling() } else { stopPolling() }

        guard inside != viewModel.isHovering else { return }
        viewModel.isHovering = inside
        hoverChanged(inside: inside)
    }

    func handleMouseDown(_ point: NSPoint) {
        if viewModel.isOpen && !hitRect().contains(point) {
            close()
        }
    }

    private func hoverChanged(inside: Bool) {
        pendingHoverWork?.cancel()
        if inside, !viewModel.isOpen, settings.hoverToOpen {
            schedule(after: settings.hoverDelay) { [weak self] in self?.open() }
        } else if !inside, viewModel.isOpen {
            schedule(after: 0.3) { [weak self] in
                guard let self, !self.viewModel.isHovering else { return }
                self.close()
            }
        }
    }

    private func schedule(after delay: Double, _ block: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        pendingHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Global mouse monitors go quiet while the cursor is over our own window,
    /// so we poll the cursor position only while it is on the notch or the notch is open.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMouseMoved(NSEvent.mouseLocation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Fullscreen

    func updateFullscreenVisibility() {
        let shouldHide = settings.hideInFullscreen && SpaceInspector.isFullscreen(screen)
        guard shouldHide != isHiddenForFullscreen else { return }
        isHiddenForFullscreen = shouldHide
        if shouldHide {
            viewModel.setOpen(false)
            viewModel.isHovering = false
            stopPolling()
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
}
