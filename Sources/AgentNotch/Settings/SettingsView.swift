import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var keys = MediaKeyInterceptor.shared
    @ObservedObject var spectrum = AudioSpectrumModel.shared
    @ObservedObject var installer = IntegrationInstaller.shared
    @ObservedObject var ci = CIModel.shared

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
            } header: {
                Text("Media")
            } footer: {
                Text("The visualizer reads your Mac's audio output live (it's never recorded) and only while something is playing. If the bars stay flat, allow AgentNotch under Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
            let window = NSWindow(contentViewController: hosting)
            window.title = "AgentNotch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
