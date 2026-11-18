import SwiftUI

/// Home: clock, battery and today's agenda on the left; now playing and agents on the right.
struct HomeTabView: View {
    var body: some View {
        HStack(spacing: 12) {
            ClockAgendaCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                MiniPlayerView()
                AgentsSummaryRow()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ClockAgendaCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var calendar = CalendarModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    PowerBadges()
                }
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                if settings.showCalendar {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.vertical, 3)
                    AgendaView(now: context.date)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card()
        }
    }
}

/// Battery and connected Bluetooth devices, small, top-right of the clock card.
private struct PowerBadges: View {
    @ObservedObject private var battery = BatteryModel.shared
    @ObservedObject private var bluetooth = BluetoothModel.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(bluetooth.connected.filter { $0.battery != nil }.prefix(1)) { device in
                badge(icon: device.icon, text: device.battery ?? "", tint: .white.opacity(0.7))
                    .help(device.name)
            }
            if battery.hasBattery {
                badge(icon: battery.icon, text: "\(battery.percent)%",
                      tint: battery.isCharging ? NotchAlert.Tint.green.color
                          : (battery.percent <= 20 ? NotchAlert.Tint.red.color : .white.opacity(0.7)))
                    .help(batteryHelp)
            }
        }
    }

    private var batteryHelp: String {
        var s = battery.isCharging ? "Charging" : (battery.onAC ? "On power adapter" : "On battery")
        if let m = battery.timeRemaining {
            s += battery.onAC ? " · full in \(BatteryModel.format(minutes: m))" : " · \(BatteryModel.format(minutes: m)) left"
        }
        return s
    }

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).symbolRenderingMode(.hierarchical)
            Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

/// Next couple of events, with a Join button for video calls that are about to start.
private struct AgendaView: View {
    let now: Date
    @ObservedObject private var calendar = CalendarModel.shared

    var body: some View {
        switch calendar.access {
        case .notDetermined:
            Button { calendar.requestAccess() } label: {
                Label("Show your calendar", systemImage: "calendar.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchAlert.Tint.blue.color)
            .help("macOS will ask to allow calendar access. Events stay on this Mac.")
        case .denied:
            Button { calendar.openPrivacySettings() } label: {
                Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.45))
            .help("Open Privacy & Security → Calendars to allow AgentNotch")
        case .granted:
            let upcoming = Array(calendar.events.prefix(2))
            if upcoming.isEmpty {
                Label("Nothing else today", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(upcoming) { EventRow(event: $0, now: now) }
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarModel.Event
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(when)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(event.isHappening(at: now) ? NotchAlert.Tint.blue.color : .white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if event.joinURL != nil, !event.isAllDay, event.start.timeIntervalSince(now) < 15 * 60 {
                Button("Join") { CalendarModel.shared.open(event) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(NotchAlert.Tint.blue.color))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { CalendarModel.shared.open(event) }
        .opacity(hovering ? 0.85 : 1)
        .onHover { hovering = $0 }
    }

    private var when: String {
        if event.isAllDay {
            return Calendar.current.isDateInToday(event.start) || event.start < now ? "All day" : "Tomorrow · all day"
        }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        if event.isHappening(at: now) {
            let left = Int(event.end.timeIntervalSince(now) / 60)
            return "Now · \(left) min left"
        }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if !Calendar.current.isDateInToday(event.start) { return "Tomorrow \(start)" }
        if minutes < 60 { return "\(start) – \(end) · in \(max(minutes, 1)) min" }
        return "\(start) – \(end)"
    }
}

private struct AgentsSummaryRow: View {
    @ObservedObject private var agents = AgentsModel.shared

    var body: some View {
        SummaryRow(icon: agents.waitingCount > 0 ? "exclamationmark.bubble.fill" : "sparkles",
                   title: "Agents", value: summary)
    }

    private var summary: String {
        let waiting = agents.waitingCount, working = agents.workingCount
        if waiting > 0, let first = agents.sessions.first(where: { $0.state == .waiting }) {
            return waiting == 1 ? "\(first.project) needs you" : "\(waiting) sessions need you"
        }
        if working > 0 { return working == 1 ? "1 session working" : "\(working) sessions working" }
        if let done = agents.sessions.first(where: { $0.state == .done }) { return "\(done.project): done" }
        return "No active sessions"
    }
}

private struct SummaryRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

struct PlaceholderTabView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}
