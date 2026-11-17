import Foundation

/// What the closed notch is showing besides plain black.
///
/// Priority: HUD > alert > an agent waiting for you > now playing > agents working > idle.
enum ClosedActivity: Equatable {
    case idle
    case hud(HUDState)
    case alert(NotchAlert)
    case agents(waiting: Int, working: Int)
    case nowPlaying(peek: Bool)

    /// Coarse identity used to drive shape animations (value changes within a kind shouldn't re-animate).
    var layoutKey: Int {
        switch self {
        case .idle: 0
        case .hud: 1
        case .nowPlaying(let peek): peek ? 3 : 2
        case .alert: 4
        case .agents: 5
        }
    }

    /// Activities that are about dev work; clicking them opens the Dev tab.
    var opensDevTab: Bool {
        switch self {
        case .alert, .agents: true
        default: false
        }
    }

    @MainActor
    static func current() -> ClosedActivity {
        current(settings: .shared, hud: .shared, media: .shared, alerts: .shared, agents: .shared)
    }

    @MainActor
    static func current(settings: AppSettings, hud: HUDModel, media: NowPlayingModel,
                        alerts: AlertCenter, agents: AgentsModel) -> ClosedActivity {
        if let state = hud.state { return .hud(state) }
        if let alert = alerts.current { return .alert(alert) }
        let waiting = agents.waitingCount, working = agents.workingCount
        if waiting > 0 { return .agents(waiting: waiting, working: working) }
        if settings.showNowPlayingActivity, media.hasMedia, media.isPlaying {
            return .nowPlaying(peek: settings.showTrackPeek && media.isPeeking)
        }
        if working > 0 { return .agents(waiting: 0, working: working) }
        return .idle
    }
}
