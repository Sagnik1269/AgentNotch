import SwiftUI

/// Dev tab: Claude Code sessions, finished commands, listening ports and CI.
struct DevTabView: View {
    enum Section: String, CaseIterable, Identifiable {
        case agents = "Agents", commands = "Commands", ports = "Ports", ci = "CI"
        var id: String { rawValue }
    }

    var onOpenSettings: () -> Void
    @State private var section: Section = .agents
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var commands = CommandsModel.shared
    @ObservedObject private var ci = CIModel.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { item in
                    SectionChip(title: item.rawValue, badge: badge(for: item), isSelected: section == item) {
                        section = item
                    }
                }
                Spacer()
            }

            Group {
                switch section {
                case .agents: AgentsList(onOpenSettings: onOpenSettings)
                case .commands: CommandsList(onOpenSettings: onOpenSettings)
                case .ports: PortsList()
                case .ci: CIList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // Land on whatever needs attention.
            if agents.waitingCount > 0 || agents.workingCount > 0 { section = .agents }
        }
    }

    private func badge(for item: Section) -> (String, Color)? {
        switch item {
        case .agents:
            if agents.waitingCount > 0 { return ("\(agents.waitingCount)", NotchAlert.Tint.orange.color) }
            if agents.workingCount > 0 { return ("\(agents.workingCount)", .white.opacity(0.25)) }
        case .ci:
            if ci.runs.contains(where: \.isRunning) { return ("•", NotchAlert.Tint.blue.color) }
        default: break
        }
        return nil
    }
}

private struct SectionChip: View {
    let title: String
    let badge: (String, Color)?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .semibold))
                if let badge {
                    Text(badge.0)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(badge.1))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(isSelected ? .white : .white.opacity(hovering ? 0.8 : 0.5))
            .background(Capsule().fill(Color.white.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rows

private struct DevRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    var monospaced = false
    var action: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(monospaced ? .system(size: 12, weight: .medium, design: .monospaced)
                                     : .system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hovering && action != nil ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}

private struct EmptyDevState: View {
    let icon: String
    let text: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

// MARK: - Agents

private struct AgentsList: View {
    var onOpenSettings: () -> Void
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var installer = IntegrationInstaller.shared

    var body: some View {
        if agents.sessions.isEmpty {
            EmptyDevState(
                icon: "sparkle",
                text: installer.claudeHooksInstalled
                    ? "No Claude Code sessions yet. Start one and it shows up here."
                    : "Connect Claude Code to see sessions working, waiting and finished.",
                buttonTitle: installer.claudeHooksInstalled ? nil : "Set up in Settings",
                action: onOpenSettings
            )
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(agents.sessions) { session in
                        DevRow(title: session.project,
                               subtitle: session.detail,
                               action: { agents.activate(session) }) {
                            AgentStateIcon(state: session.state)
                        } trailing: {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text(ago(session.updatedAt))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .help(session.lastPrompt ?? session.cwd)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct AgentStateIcon: View {
    let state: AgentSession.State

    var body: some View {
        switch state {
        case .working: ProgressView().controlSize(.small).scaleEffect(0.7).tint(.white)
        case .waiting: AgentGlyph(waiting: true)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                .foregroundStyle(NotchAlert.Tint.green.color)
        case .idle:
            Image(systemName: "circle.dotted").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Commands

private struct CommandsList: View {
    var onOpenSettings: () -> Void
    @ObservedObject private var commands = CommandsModel.shared
    @ObservedObject private var installer = IntegrationInstaller.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if commands.recent.isEmpty {
            EmptyDevState(
                icon: "terminal",
                text: installer.shellInstalled
                    ? "Commands that run longer than \(Int(settings.commandAlertThreshold))s show up here."
                    : "Add the zsh integration to get alerts when long commands finish.",
                buttonTitle: installer.shellInstalled ? nil : "Set up in Settings",
                action: onOpenSettings
            )
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(commands.recent) { run in
                        DevRow(title: run.command,
                               subtitle: "\(run.succeeded ? "" : "exit \(run.exitCode) · ")\(AgentsModel.formatDuration(run.duration)) · \(run.folder)",
                               monospaced: true,
                               action: { AlertCenter.activate(bundleID: run.appBundleID) }) {
                            Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(run.succeeded ? NotchAlert.Tint.green.color : NotchAlert.Tint.red.color)
                        } trailing: {
                            Text(ago(run.finishedAt))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Ports

private struct PortsList: View {
    @ObservedObject private var model = PortsModel.shared
    @State private var confirmKill: String?

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.ports.isEmpty {
                EmptyDevState(icon: "network", text: "Nothing is listening on a local port.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.ports) { port in
                            DevRow(title: ":\(port.port)", subtitle: "\(port.process) · pid \(port.pid)",
                                   monospaced: true, action: { model.open(port) }) {
                                Image(systemName: port.isDevServer ? "server.rack" : "app.dashed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(port.isDevServer ? 0.8 : 0.4))
                            } trailing: {
                                HStack(spacing: 6) {
                                    MiniButton(systemName: "safari", help: "Open in browser") { model.open(port) }
                                    if confirmKill == port.id {
                                        MiniButton(title: "Quit?", tint: NotchAlert.Tint.red.color, help: "Send SIGTERM") {
                                            model.terminate(port)
                                            confirmKill = nil
                                        }
                                    } else {
                                        MiniButton(systemName: "xmark", help: "Stop this process") {
                                            confirmKill = port.id
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                                if confirmKill == port.id { confirmKill = nil }
                                            }
                                        }
                                    }
                                }
                            }
                            .opacity(port.isDevServer ? 1 : 0.7)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }
}

private struct MiniButton: View {
    var systemName: String?
    var title: String?
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 10, weight: .bold))
                } else if let title {
                    Text(title).font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(tint.opacity(hovering ? 1 : 0.75))
            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 20)
            .background(Capsule().fill(tint.opacity(hovering ? 0.22 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - CI

private struct CIList: View {
    @ObservedObject private var ci = CIModel.shared

    var body: some View {
        switch ci.ghStatus {
        case .missing:
            EmptyDevState(icon: "exclamationmark.triangle",
                          text: "Install the GitHub CLI (brew install gh) to see Actions runs.")
        case .loggedOut:
            EmptyDevState(icon: "person.crop.circle.badge.exclamationmark",
                          text: "Run `gh auth login` in a terminal to see Actions runs.")
        case .unknown:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if ci.runs.isEmpty {
                EmptyDevState(icon: "checkmark.seal",
                              text: "Runs for the branches you work on (in Claude or the terminal) show up here.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(ci.runs) { run in
                            DevRow(title: "\(run.repoName) · \(run.branch)",
                                   subtitle: "\(run.workflow): \(run.title)",
                                   action: { ci.open(run) }) {
                                CIStateIcon(run: run)
                            } trailing: {
                                if let date = run.updatedAt {
                                    Text(ago(date))
                                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct CIStateIcon: View {
    let run: CIRun

    var body: some View {
        if run.isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.7).tint(NotchAlert.Tint.blue.color)
        } else if run.succeeded {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(NotchAlert.Tint.green.color)
        } else if run.conclusion == "cancelled" || run.conclusion == "skipped" {
            Image(systemName: "minus.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
        } else {
            Image(systemName: "xmark.seal.fill").font(.system(size: 13)).foregroundStyle(NotchAlert.Tint.red.color)
        }
    }
}
