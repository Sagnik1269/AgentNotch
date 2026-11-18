import Foundation
import ServiceManagement

enum DisplayMode: String, CaseIterable, Identifiable {
    case allDisplays
    case notchedOnly
    case mainOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allDisplays: "All displays"
        case .notchedOnly: "Built-in notch display only"
        case .mainOnly: "Main display only"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: Keys.hoverToOpen) } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: Keys.haptics) } }
    @Published var hideInFullscreen: Bool { didSet { defaults.set(hideInFullscreen, forKey: Keys.hideInFullscreen) } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) } }

    // Media
    @Published var showNowPlayingActivity: Bool { didSet { defaults.set(showNowPlayingActivity, forKey: Keys.showNowPlayingActivity) } }
    @Published var showTrackPeek: Bool { didSet { defaults.set(showTrackPeek, forKey: Keys.showTrackPeek) } }
    @Published var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: Keys.showVisualizer) } }
    /// Off by default: turning it on sends the current track's title/artist to lrclib.net.
    @Published var liveLyrics: Bool { didSet { defaults.set(liveLyrics, forKey: Keys.liveLyrics) } }
    /// Show non-Latin lyrics in Latin letters ("tum hi ho"). Transliteration, not translation.
    @Published var romanizeLyrics: Bool { didSet { defaults.set(romanizeLyrics, forKey: Keys.romanizeLyrics) } }
    @Published var lyricsInClosedNotch: Bool { didSet { defaults.set(lyricsInClosedNotch, forKey: Keys.lyricsInClosedNotch) } }
    /// Seconds added to the playback position when picking the lyric line (positive = earlier lines).
    @Published var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: Keys.lyricsOffset) } }

    // HUD
    @Published var replaceSystemHUD: Bool { didSet { defaults.set(replaceSystemHUD, forKey: Keys.replaceSystemHUD) } }

    // Developer
    /// Only commands that ran at least this long (seconds) are listed and announced.
    @Published var commandAlertThreshold: Double { didSet { defaults.set(commandAlertThreshold, forKey: Keys.commandAlertThreshold) } }
    /// Skip alerts when the app that produced them (your terminal, Claude) is frontmost.
    @Published var quietWhenFocused: Bool { didSet { defaults.set(quietWhenFocused, forKey: Keys.quietWhenFocused) } }

    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginError: String?

    private enum Keys {
        static let hoverToOpen = "hoverToOpen"
        static let hoverDelay = "hoverDelay"
        static let haptics = "haptics"
        static let hideInFullscreen = "hideInFullscreen"
        static let displayMode = "displayMode"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showNowPlayingActivity = "showNowPlayingActivity"
        static let showTrackPeek = "showTrackPeek"
        static let showVisualizer = "showVisualizer"
        static let liveLyrics = "liveLyrics"
        static let lyricsInClosedNotch = "lyricsInClosedNotch"
        static let romanizeLyrics = "romanizeLyrics"
        static let lyricsOffset = "lyricsOffset"
        static let replaceSystemHUD = "replaceSystemHUD"
        static let commandAlertThreshold = "commandAlertThreshold"
        static let quietWhenFocused = "quietWhenFocused"
    }

    private init() {
        defaults.register(defaults: [
            Keys.hoverToOpen: true,
            Keys.hoverDelay: 0.15,
            Keys.haptics: true,
            Keys.hideInFullscreen: true,
            Keys.displayMode: DisplayMode.allDisplays.rawValue,
            Keys.showMenuBarIcon: true,
            Keys.showNowPlayingActivity: true,
            Keys.showTrackPeek: true,
            Keys.showVisualizer: true,
            Keys.liveLyrics: false,
            Keys.lyricsInClosedNotch: true,
            Keys.romanizeLyrics: true,
            Keys.lyricsOffset: 0.0,
            Keys.replaceSystemHUD: true,
            Keys.commandAlertThreshold: 10.0,
            Keys.quietWhenFocused: true,
        ])
        hoverToOpen = defaults.bool(forKey: Keys.hoverToOpen)
        hoverDelay = defaults.double(forKey: Keys.hoverDelay)
        haptics = defaults.bool(forKey: Keys.haptics)
        hideInFullscreen = defaults.bool(forKey: Keys.hideInFullscreen)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .allDisplays
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        showNowPlayingActivity = defaults.bool(forKey: Keys.showNowPlayingActivity)
        showTrackPeek = defaults.bool(forKey: Keys.showTrackPeek)
        showVisualizer = defaults.bool(forKey: Keys.showVisualizer)
        liveLyrics = defaults.bool(forKey: Keys.liveLyrics)
        lyricsInClosedNotch = defaults.bool(forKey: Keys.lyricsInClosedNotch)
        romanizeLyrics = defaults.bool(forKey: Keys.romanizeLyrics)
        lyricsOffset = defaults.double(forKey: Keys.lyricsOffset)
        replaceSystemHUD = defaults.bool(forKey: Keys.replaceSystemHUD)
        commandAlertThreshold = defaults.double(forKey: Keys.commandAlertThreshold)
        quietWhenFocused = defaults.bool(forKey: Keys.quietWhenFocused)
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }
}
