import SwiftUI

/// Home: clock and today's agenda on the left; now playing and batteries on the right.
struct HomeTabView: View {
    var body: some View {
        HStack(spacing: 12) {
            ClockAgendaCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                MiniPlayerView()
                BatteryModule()
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
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
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

/// Every battery in one place: this Mac, plus connected Bluetooth devices (AirPods per bud + case).
private struct BatteryModule: View {
    @ObservedObject private var battery = BatteryModel.shared
    @ObservedObject private var bluetooth = BluetoothModel.shared
    @ObservedObject private var settings = AppSettings.shared

    @ObservedObject private var ble = BLEBatteryReader.shared

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let percent: Int?
        var charging = false
        let help: String
    }

    /// This Mac, then every connected device. Devices are merged by name across the two Bluetooth
    /// sources; ones that don't report a battery are still shown (dimmed, "–").
    private var items: [Item] {
        var out: [Item] = []
        if battery.hasBattery {
            out.append(Item(id: "mac", icon: "laptopcomputer", percent: battery.percent,
                            charging: battery.isCharging, help: macHelp))
        }
        var seen = Set<String>()
        for device in bluetooth.connected {
            let key = BLEBatteryReader.key(device.name)
            if !device.levels.isEmpty {
                seen.insert(key)
                for level in device.levels {
                    out.append(Item(id: device.id + level.label, icon: level.icon, percent: level.percent,
                                    help: level.label == device.name ? device.name : "\(device.name) · \(level.label)"))
                }
            }
        }
        for reading in ble.devices where !seen.contains(BLEBatteryReader.key(reading.name)) {
            seen.insert(BLEBatteryReader.key(reading.name))
            let icon = BluetoothModel.icon(forName: reading.name) ?? "dot.radiowaves.left.and.right"
            out.append(Item(id: reading.id.uuidString, icon: icon, percent: reading.percent,
                            help: reading.percent == nil ? "\(reading.name) · battery not reported" : reading.name))
        }
        for device in bluetooth.connected where !seen.contains(BLEBatteryReader.key(device.name)) {
            seen.insert(BLEBatteryReader.key(device.name))
            out.append(Item(id: device.id, icon: device.icon, percent: nil,
                            help: "\(device.name) · battery not reported"))
        }
        return out
    }

    var body: some View {
        let items = items
        let showAdd = !settings.showDeviceBatteries && !settings.bluetoothAlerts
        GeometryReader { geo in
            // Rings shrink (34 → 24 pt) so every device fits; past that the row scrolls.
            let count = CGFloat(items.count + (showAdd ? 1 : 0))
            let spacing: CGFloat = count > 5 ? 8 : 14
            let fit = (geo.size.width - 24 - spacing * max(count - 1, 0)) / max(count, 1)
            let ring = min(34, max(24, fit))
            ScrollView(.horizontal, showsIndicators: false) {
                row(items: items, showAdd: showAdd, ring: ring, spacing: spacing)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private func row(items: [Item], showAdd: Bool, ring: CGFloat, spacing: CGFloat) -> some View {
            HStack(spacing: spacing) {
                ForEach(items) { item in
                    BatteryRing(icon: item.icon, percent: item.percent, charging: item.charging, help: item.help, size: ring)
                }
                if showAdd {
                    Button { settings.showDeviceBatteries = true } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: ring, height: ring)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25),
                                                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                            Text("Devices").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Show AirPods, keyboards, mice and other Bluetooth device batteries (macOS will ask for Bluetooth access)")
                } else if items.isEmpty {
                    Text("No batteries to show").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
    }

    private var macHelp: String {
        var s = "This Mac · " + (battery.isCharging ? "Charging" : (battery.onAC ? "On power adapter" : "On battery"))
        if let m = battery.timeRemaining {
            s += battery.onAC ? " · full in \(BatteryModel.format(minutes: m))" : " · \(BatteryModel.format(minutes: m)) left"
        }
        return s
    }
}

/// A battery level as a ring around the device icon, with the percentage underneath.
private struct BatteryRing: View {
    let icon: String
    let percent: Int?
    let charging: Bool
    let help: String
    var size: CGFloat = 34

    var body: some View {
        let value = percent ?? 0
        let tint: Color = percent == nil ? .white.opacity(0.4)
            : charging ? NotchAlert.Tint.green.color
            : (value <= 20 ? NotchAlert.Tint.red.color : .white)
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 100)) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: icon)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(percent == nil ? 0.45 : 0.85))
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint)
                        .offset(x: size * 0.36, y: -size * 0.36)
                }
            }
            .frame(width: size, height: size)
            Text(percent.map { "\($0)%" } ?? "–")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint.opacity(0.9))
        }
        .help(help)
        .animation(.easeOut(duration: 0.3), value: percent)
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
