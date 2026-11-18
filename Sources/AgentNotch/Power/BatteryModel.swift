import Foundation
import IOKit.ps
import notify

/// Internal battery state from IOKit power sources, with change notifications (no polling).
@MainActor
final class BatteryModel: ObservableObject {
    static let shared = BatteryModel()

    @Published private(set) var hasBattery = false
    @Published private(set) var percent = 0
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = false
    @Published private(set) var isCharged = false
    /// Minutes, when macOS has an estimate.
    @Published private(set) var timeRemaining: Int?

    private var runLoopSource: CFRunLoopSource?
    private var notifyTokens: [Int32] = []
    private var pollTimer: Timer?
    private var lowAlertedAt: Int?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        read(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let model = Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { model.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        // The dedicated "power source changed" (AC ↔ battery) signal, adapter attach, and any change.
        for key in [kIOPSNotifyPowerSource, kIOPSNotifyAttach, kIOPSNotifyAnyPowerSource] {
            var token: Int32 = 0
            let status = notify_register_dispatch(key, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.powerChanged() }
            }
            if status == NOTIFY_STATUS_OK { notifyTokens.append(token) }
        }
        // Safety net in case a notification is missed (cheap: one IOKit read every 20 s).
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(announce: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// The adapter state can lag the notification slightly, so read now and again shortly after.
    private func powerChanged() {
        read(announce: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.read(announce: true) }
        }
    }

    var icon: String { Self.icon(percent: percent, charging: isCharging || (onAC && isCharged)) }

    static func icon(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func read(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let battery = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let d = battery else {
            hasBattery = false
            return
        }
        let wasOnAC = onAC, wasKnown = hasBattery
        hasBattery = true
        let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
        isCharged = d[kIOPSIsChargedKey] as? Bool ?? false
        onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = (onAC ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
        timeRemaining = minutes > 0 ? minutes : nil

        guard announce, wasKnown else { return }
        let settings = AppSettings.shared
        if onAC != wasOnAC {
            NSLog("AgentNotch: power source changed: \(onAC ? "AC" : "battery") at \(percent)%")
        }
        if onAC != wasOnAC, settings.batteryPops {
            StatusPopModel.shared.show(StatusPop(
                icon: onAC ? "battery.100percent.bolt" : Self.icon(percent: percent, charging: false),
                text: "\(percent)%",
                tint: onAC ? .green : (percent <= 20 ? .red : .white)))
        }
        if onAC { lowAlertedAt = nil }
        // Low-battery alerts at 20 % and 10 %, once each per discharge.
        if !onAC, settings.lowBatteryAlerts {
            for threshold in [10, 20] where percent <= threshold && (lowAlertedAt ?? 101) > threshold {
                lowAlertedAt = threshold
                AlertCenter.shared.post(NotchAlert(
                    icon: "battery.25percent", tint: .red, title: "Battery low",
                    subtitle: "\(percent)% left" + (timeRemaining.map { " · about \(Self.format(minutes: $0))" } ?? ""),
                    tab: .home))
                break
            }
        }
    }

    static func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
