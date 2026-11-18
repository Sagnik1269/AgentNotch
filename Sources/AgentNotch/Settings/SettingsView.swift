import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var keys = MediaKeyInterceptor.shared
    @ObservedObject var spectrum = AudioSpectrumModel.shared
    @ObservedObject var installer = IntegrationInstaller.shared
    @ObservedObject var ci = CIModel.shared
    @ObservedObject var shelf = ShelfModel.shared
    @ObservedObject var calendar = CalendarModel.shared

    @ViewBuilder private var developerSection: some View {
        Section {
            IntegrationRow(
                title: "Claude Code",
                detail: "Adds AgentNotch hooks to ~/.claude/settings.json next to your existing hooks. A backup is saved first. Applies to new sessions.",
                installed: installer.claudeHooksInstalled,
                toggle: { installer.setClaudeHooks(installed: !installer.claudeHooksInstalled) }
            )
            IntegrationRow(
                title: "zsh",
                detail: "Adds one marked line to ~/.zshrc (backup saved). Open a new terminal tab afterwards.",
                installed: installer.shellInstalled,
                toggle: { installer.setShellIntegration(installed: !installer.shellInstalled) }
            )
            if let error = installer.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Alert for commands longer than") {
                HStack {
                    Slider(value: $settings.commandAlertThreshold, in: 3...120, step: 1)
                        .frame(width: 140)
                    Text("\(Int(settings.commandAlertThreshold))s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Toggle("Skip alerts when that app is in front", isOn: $settings.quietWhenFocused)
            LabeledContent("GitHub Actions") {
                switch ci.ghStatus {
                case .ready: Label("Using gh", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .loggedOut: Text("Run `gh auth login`").foregroundStyle(.orange)
                case .missing: Text("Install GitHub CLI (`brew install gh`)").foregroundStyle(.secondary)
                case .unknown: ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send your own alerts from any script:")
                Text("curl --unix-socket \"$HOME/Library/Application Support/AgentNotch/agentnotch.sock\" -d '{\"title\":\"Deploy done\",\"tint\":\"green\"}' http://localhost/v1/notify")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { installer.refresh() }
    }

    @ViewBuilder private var visualizerStatus: some View {
        HStack {
            switch spectrum.status {
            case .running:
                Label("Listening", systemImage: "waveform").foregroundStyle(.green)
            case .off:
                Label("Starts when music plays", systemImage: "pause.circle").foregroundStyle(.secondary)
            case .unsupported:
                Label("Needs macOS 14.2 or later", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button("Privacy Settings…") { AudioSpectrumModel.openPrivacySettings() }
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            }

            Section("Behavior") {
                Toggle("Open on hover", isOn: $settings.hoverToOpen)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: 0...0.8, step: 0.05)
                            .frame(width: 160)
                        Text("\(Int(settings.hoverDelay * 1000)) ms")
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                .disabled(!settings.hoverToOpen)
                Toggle("Haptic feedback", isOn: $settings.haptics)
                Toggle("Hide when an app is fullscreen", isOn: $settings.hideInFullscreen)
            }

            Section {
                Toggle("Show now playing in the closed notch", isOn: $settings.showNowPlayingActivity)
                Toggle("Preview the song when the track changes", isOn: $settings.showTrackPeek)
                    .disabled(!settings.showNowPlayingActivity)
                Toggle("Audio visualizer", isOn: $settings.showVisualizer)
                if settings.showVisualizer {
                    visualizerStatus
                }
                Toggle("Live lyrics", isOn: $settings.liveLyrics)
                if settings.liveLyrics {
                    Toggle("Show the current line in the closed notch", isOn: $settings.lyricsInClosedNotch)
                        .disabled(!settings.showNowPlayingActivity)
                    Toggle("Write lyrics in English letters (e.g. \"tum hi ho\")", isOn: $settings.romanizeLyrics)
                    LabeledContent("Timing for all songs") {
                        HStack(spacing: 8) {
                            Text(settings.lyricsOffset == 0 ? "In sync"
                                 : String(format: "%+.1f s %@", settings.lyricsOffset,
                                          settings.lyricsOffset > 0 ? "earlier" : "later"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper("", value: $settings.lyricsOffset, in: -2...2, step: 0.1)
                                .labelsHidden()
                            Button("Reset") { settings.lyricsOffset = 0 }
                                .disabled(settings.lyricsOffset == 0)
                        }
                    }
                }
            } header: {
                Text("Media")
            } footer: {
                Text("Live lyrics look up the playing song's title, artist, album and length on lrclib.net, once per song (results are cached on this Mac). Nothing is sent while it's off. If one song is out of sync, ⌥-click (or right-click) the line you're hearing in the Media tab; that fix is remembered for that song. The all-songs timing is for constant delays such as Bluetooth headphones. The visualizer reads your Mac's audio output live (it's never recorded) and only while something is playing. If the bars stay flat, allow AgentNotch under Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Replace volume & brightness HUD", isOn: $settings.replaceSystemHUD)
                if settings.replaceSystemHUD {
                    if keys.isRunning {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("Needs Accessibility permission", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Settings…") { MediaKeyInterceptor.openAccessibilitySettings() }
                        }
                    }
                }
            } header: {
                Text("HUD")
            } footer: {
                Text("Volume and built-in display brightness keys show in the notch. Option+Shift gives finer steps. Outputs without software volume (some HDMI/DisplayPort monitors) and keyboard backlight keep the system HUD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shelf") {
                Toggle("Open the shelf when dragging files to the notch", isOn: $settings.shelfOnDrag)
                LabeledContent("Items on the shelf") {
                    HStack {
                        Text("\(shelf.items.count)").foregroundStyle(.secondary)
                        Button("Clear") { shelf.clear() }.disabled(shelf.items.isEmpty)
                    }
                }
            }

            Section {
                Toggle("Show upcoming events on Home", isOn: $settings.showCalendar)
                LabeledContent("Calendar access") {
                    switch calendar.access {
                    case .granted:
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined:
                        Button("Allow…") { calendar.requestAccess() }
                    case .denied:
                        Button("Open Privacy Settings…") { calendar.openPrivacySettings() }
                    }
                }
                Toggle("Alert before events start", isOn: $settings.calendarAlerts)
                    .disabled(!settings.showCalendar)
                if settings.calendarAlerts && settings.showCalendar {
                    Picker("Alert", selection: $settings.calendarAlertMinutes) {
                        Text("1 minute before").tag(1)
                        Text("5 minutes before").tag(5)
                        Text("10 minutes before").tag(10)
                        Text("15 minutes before").tag(15)
                    }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Reads the calendars already set up in macOS (iCloud, Google, Exchange…). Events stay on this Mac. Video-call links (Meet, Zoom, Teams…) get a Join button.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show charging status when plugging in or unplugging", isOn: $settings.batteryPops)
                Toggle("Low battery alerts (20% and 10%)", isOn: $settings.lowBatteryAlerts)
                Toggle("Bluetooth device alerts", isOn: $settings.bluetoothAlerts)
            } header: {
                Text("Battery & devices")
            } footer: {
                Text("Bluetooth alerts show when headphones, keyboards and other devices connect, with battery levels when the device reports them. macOS asks for Bluetooth permission the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            developerSection

            Section("Displays") {
                Picker("Show notch on", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("Displays without a camera notch get a virtual one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("AgentNotch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit AgentNotch") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        // Fixed width; height comes from the window, and the grouped form scrolls inside it.
        .frame(width: 460)
        .frame(minHeight: 300, maxHeight: .infinity)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

private struct IntegrationRow: View {
    let title: String
    let detail: String
    let installed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(installed ? "Remove" : "Install", action: toggle)
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            // Don't let SwiftUI grow the window to the form's full height (taller than most screens).
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "AgentNotch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 460, height: 300)
            window.contentMaxSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(Self.defaultSize(on: NSScreen.main))
            window.center()
            self.window = window
        }
        if let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
           !visible.contains(window.frame) {
            // Opened before on a bigger display, or the old oversized frame: bring it back on screen.
            window.setContentSize(Self.defaultSize(on: window.screen ?? NSScreen.main))
            window.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 600 pt tall, or less on short screens, always leaving room for the title bar.
    private static func defaultSize(on screen: NSScreen?) -> NSSize {
        let available = (screen?.visibleFrame.height ?? 800) - 80
        return NSSize(width: 460, height: max(300, min(600, available)))
    }
}
