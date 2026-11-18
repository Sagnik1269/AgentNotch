import Foundation

/// What the closed notch is showing besides plain black.
///
/// Priority: HUD > status pop (battery) > alert > an agent waiting for you > now playing > agents working > idle.
enum ClosedActivity: Equatable {
    case idle
    case hud(HUDState)
    case status(StatusPop)
    case alert(NotchAlert)
    case agents(waiting: Int, working: Int)
    case nowPlaying(row: NowPlayingRow)

    /// Optional row under the notch while music plays.
    enum NowPlayingRow: Equatable {
        case none
        case peek       // title/artist for a few seconds after a track change
        case lyric      // the live lyric line
    }

    /// Coarse identity used to drive shape animations (value changes within a kind shouldn't re-animate).
    var layoutKey: Int {
        switch self {
        case .idle: 0
        case .hud: 1
        case .nowPlaying(let row):
            switch row {
            case .none: 2
            case .peek: 3
            case .lyric: 6
            }
        case .alert: 4
        case .agents: 5
        case .status: 7
        }
    }

    /// Tab to open when the closed notch is clicked during this activity (nil = keep the current tab).
    var opensTab: NotchTab? {
        switch self {
        case .alert(let alert): alert.tab
        case .agents: .dev
        default: nil
        }
    }

    @MainActor
    static func current() -> ClosedActivity {
        current(settings: .shared, hud: .shared, media: .shared, alerts: .shared, agents: .shared, lyrics: .shared)
    }

    @MainActor
    static func current(settings: AppSettings, hud: HUDModel, media: NowPlayingModel,
                        alerts: AlertCenter, agents: AgentsModel, lyrics: LyricsModel) -> ClosedActivity {
        if let state = hud.state { return .hud(state) }
        if let pop = StatusPopModel.shared.current { return .status(pop) }
        if let alert = alerts.current { return .alert(alert) }
        let waiting = agents.waitingCount, working = agents.workingCount
        if waiting > 0 { return .agents(waiting: waiting, working: working) }
        if settings.showNowPlayingActivity, media.hasMedia, media.isPlaying {
            if settings.showTrackPeek && media.isPeeking { return .nowPlaying(row: .peek) }
            if settings.liveLyrics, settings.lyricsInClosedNotch, lyrics.state == .synced {
                return .nowPlaying(row: .lyric)
            }
            return .nowPlaying(row: .none)
        }
        if working > 0 { return .agents(waiting: 0, working: working) }
        return .idle
    }
}
