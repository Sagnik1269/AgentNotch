import AppKit
import SwiftUI

/// A short-lived notification that drops out of the closed notch.
struct NotchAlert: Equatable, Identifiable {
    enum Tint: Equatable {
        case green, red, orange, blue, white

        var color: Color {
            switch self {
            case .green: Color(red: 0.30, green: 0.85, blue: 0.45)
            case .red: Color(red: 1.0, green: 0.36, blue: 0.34)
            case .orange: Color(red: 1.0, green: 0.62, blue: 0.2)
            case .blue: Color(red: 0.35, green: 0.62, blue: 1.0)
            case .white: .white
            }
        }
    }

    let id = UUID()
    var icon: String
    var tint: Tint
    var title: String
    var subtitle: String = ""
    /// Tab opened when you click the alert.
    var tab: NotchTab = .dev
    /// Alerts with the same key replace each other instead of queueing (e.g. one device's status).
    var key: String?
    /// Seconds fully visible; nil = default (4.5 s, 3 s when others are waiting).
    var duration: Double?
}

extension Animation {
    /// Popups ease in gently (slow start) and leave quickly.
    static let notchPopIn = Animation.timingCurve(0.5, 0, 0.3, 1, duration: 0.55)
    static let notchPopOut = Animation.easeIn(duration: 0.2)
}

@MainActor
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    @Published private(set) var current: NotchAlert?
    private var queue: [NotchAlert] = []
    private var hideTask: DispatchWorkItem?

    /// Shows the alert now, or after the current one (at most 3 waiting; older ones are dropped).
    func post(_ alert: NotchAlert) {
        if let key = alert.key {
            // Same subject: update what's showing (and restart its timer) or what's waiting.
            if current?.key == key {
                show(alert, animated: false)
                return
            }
            if let i = queue.firstIndex(where: { $0.key == key }) {
                queue[i] = alert
                return
            }
        }
        if current == nil {
            show(alert)
        } else {
            queue.append(alert)
            if queue.count > 3 { queue.removeFirst(queue.count - 3) }
        }
    }

    func dismiss() {
        hideTask?.cancel()
        withAnimation(.notchPopOut) { current = nil }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated { self?.show(next) }
            }
        }
    }

    private func show(_ alert: NotchAlert, animated: Bool = true) {
        if animated {
            withAnimation(.notchPopIn) { current = alert }
        } else {
            current = alert
        }
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        hideTask = task
        // Visible time starts once the slide-in has finished.
        let visible = alert.duration ?? (queue.isEmpty ? 4.5 : 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + visible + (animated ? 0.55 : 0), execute: task)
    }

    /// True when the app that produced an event is the one you're looking at.
    static func isFrontmost(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func activate(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate()
    }

    /// Maps $TERM_PROGRAM to an app, for shells where __CFBundleIdentifier isn't set.
    static func bundleID(bundleHeader: String?, termProgram: String?) -> String? {
        if let id = bundleHeader, !id.isEmpty { return id }
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WezTerm": return "com.github.wez.wezterm"
        case "Hyper": return "co.zeit.hyper"
        default: return nil
        }
    }
}
