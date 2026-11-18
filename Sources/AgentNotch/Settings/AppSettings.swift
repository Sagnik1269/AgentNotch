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
    /// Claude Code sessions in the notch (closed-notch status, Dev tab list, alerts). Off by default.
    @Published var showAgents: Bool { didSet { defaults.set(showAgents, forKey: Keys.showAgents) } }
    /// List connected Bluetooth devices' batteries on Home (macOS asks for Bluetooth permission).
    @Published var showDeviceBatteries: Bool { didSet { defaults.set(showDeviceBatteries, forKey: Keys.showDeviceBatteries) } }

    // Shelf, calendar, power
    @Published var shelfOnDrag: Bool { didSet { defaults.set(shelfOnDrag, forKey: Keys.shelfOnDrag) } }
    /// Show events (once calendar access is granted).
    @Published var showCalendar: Bool { didSet { defaults.set(showCalendar, forKey: Keys.showCalendar) } }
    @Published var calendarAlerts: Bool { didSet { defaults.set(calendarAlerts, forKey: Keys.calendarAlerts) } }
    @Published var calendarAlertMinutes: Int { didSet { defaults.set(calendarAlertMinutes, forKey: Keys.calendarAlertMinutes) } }
    @Published var batteryPops: Bool { didSet { defaults.set(batteryPops, forKey: Keys.batteryPops) } }
    @Published var lowBatteryAlerts: Bool { didSet { defaults.set(lowBatteryAlerts, forKey: Keys.lowBatteryAlerts) } }
    /// Off by default: macOS asks for Bluetooth permission the first time it's used.
    @Published var bluetoothAlerts: Bool { didSet { defaults.set(bluetoothAlerts, forKey: Keys.bluetoothAlerts) } }

    // Tools
    @Published var showTimerInNotch: Bool { didSet { defaults.set(showTimerInNotch, forKey: Keys.showTimerInNotch) } }
    @Published var showMirrorButton: Bool { didSet { defaults.set(showMirrorButton, forKey: Keys.showMirrorButton) } }
    /// Tabs hidden from the header (Home can't be hidden).
    @Published var hiddenTabs: Set<NotchTab> {
        didSet { defaults.set(hiddenTabs.map(\.rawValue).sorted(), forKey: Keys.hiddenTabs) }
    }

    var visibleTabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || !hiddenTabs.contains($0) } }

    func setTab(_ tab: NotchTab, visible: Bool) {
        guard tab != .home else { return }
        if visible { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
    }

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
        static let shelfOnDrag = "shelfOnDrag"
        static let showAgents = "showAgents"
        static let showTimerInNotch = "showTimerInNotch"
        static let showMirrorButton = "showMirrorButton"
        static let hiddenTabs = "hiddenTabs"
        static let showDeviceBatteries = "showDeviceBatteries"
        static let showCalendar = "showCalendar"
        static let calendarAlerts = "calendarAlerts"
        static let calendarAlertMinutes = "calendarAlertMinutes"
        static let batteryPops = "batteryPops"
        static let lowBatteryAlerts = "lowBatteryAlerts"
        static let bluetoothAlerts = "bluetoothAlerts"
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
            Keys.shelfOnDrag: true,
            Keys.showAgents: false,
            Keys.showTimerInNotch: true,
            Keys.showMirrorButton: true,
            Keys.showDeviceBatteries: false,
            Keys.showCalendar: true,
            Keys.calendarAlerts: true,
            Keys.calendarAlertMinutes: 5,
            Keys.batteryPops: true,
            Keys.lowBatteryAlerts: true,
            Keys.bluetoothAlerts: false,
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
        shelfOnDrag = defaults.bool(forKey: Keys.shelfOnDrag)
        showAgents = defaults.bool(forKey: Keys.showAgents)
        showTimerInNotch = defaults.bool(forKey: Keys.showTimerInNotch)
        showMirrorButton = defaults.bool(forKey: Keys.showMirrorButton)
        hiddenTabs = Set((defaults.stringArray(forKey: Keys.hiddenTabs) ?? []).compactMap(NotchTab.init(rawValue:)))
        showDeviceBatteries = defaults.bool(forKey: Keys.showDeviceBatteries)
        showCalendar = defaults.bool(forKey: Keys.showCalendar)
        calendarAlerts = defaults.bool(forKey: Keys.calendarAlerts)
        calendarAlertMinutes = defaults.integer(forKey: Keys.calendarAlertMinutes)
        batteryPops = defaults.bool(forKey: Keys.batteryPops)
        lowBatteryAlerts = defaults.bool(forKey: Keys.lowBatteryAlerts)
        bluetoothAlerts = defaults.bool(forKey: Keys.bluetoothAlerts)
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
