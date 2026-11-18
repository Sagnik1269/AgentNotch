import AppKit
import IOBluetooth
import IOKit

/// Bluetooth connect/disconnect announcements with battery levels where the device reports them.
/// Only runs when "Bluetooth device alerts" is on (macOS asks for Bluetooth permission first).
@MainActor
final class BluetoothModel: NSObject, ObservableObject {
    static let shared = BluetoothModel()

    struct Device: Identifiable, Equatable {
        let id: String          // address
        var name: String
        var icon: String
        var levels: [Level] = []

        struct Level: Equatable, Identifiable {
            var id: String { label }
            let label: String   // "Left", "Right", "Case", or the device name
            let icon: String
            let percent: Int
        }

        /// "L 80% · R 82% · Case 60%" or "75%", for alerts.
        var batteryText: String? {
            guard !levels.isEmpty else { return nil }
            if levels.count == 1 { return "\(levels[0].percent)%" }
            return levels.map { "\($0.label == "Case" ? "Case" : String($0.label.prefix(1))) \($0.percent)%" }
                .joined(separator: " · ")
        }
    }

    @Published private(set) var connected: [Device] = []

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date.distantPast
    private var devices: [String: IOBluetoothDevice] = [:]
    private var refreshTimer: Timer?
    /// AirPods and other multi-profile devices report several connects in a row; each new one
    /// restarts this per-device timer so only the last one announces.
    private var pendingAnnounce: [String: DispatchWorkItem] = [:]
    /// Last connect/disconnect announcement per device name, to drop link flapping.
    private var lastAnnounced: [String: (connected: Bool, at: Date)] = [:]

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard connectNotification == nil else { return }
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
        // Devices that were already connected before we started.
        for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where device.isConnected() {
            deviceConnected(nil, device: device)
        }
        // Battery levels drift; refresh them every minute while tracking.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLevels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshLevels() {
        for (address, device) in devices where device.isConnected() {
            guard var entry = connected.first(where: { $0.id == address }) else { continue }
            entry.levels = Self.levels(for: device)
            upsert(entry)
        }
    }

    private func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        pendingAnnounce.values.forEach { $0.cancel() }
        pendingAnnounce.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        devices.removeAll()
        connected.removeAll()
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification?, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        devices[address] = device
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
        // Devices already connected at start are reported immediately: list them, don't announce.
        let announce = Date().timeIntervalSince(startedAt) > 3
        if let name = device.name {
            upsert(Device(id: address, name: name, icon: Self.icon(for: device)))
        }
        // Wait for the burst of connects to settle; by then the name and battery levels are known.
        pendingAnnounce[address]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingAnnounce[address] = nil
                guard device.isConnected(), let name = device.name, !name.isEmpty else { return }
                let entry = Device(id: address, name: name, icon: Self.icon(for: device),
                                   levels: Self.levels(for: device))
                self.upsert(entry)
                guard announce, AppSettings.shared.bluetoothAlerts, self.shouldAnnounce(name, connected: true) else { return }
                AlertCenter.shared.post(NotchAlert(icon: entry.icon, tint: .blue,
                                                   title: "\(name) connected",
                                                   subtitle: entry.batteryText ?? "", tab: .home,
                                                   key: "bluetooth:\(name)", duration: 2))
            }
        }
        pendingAnnounce[address] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (announce ? 2.5 : 0.5), execute: work)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        pendingAnnounce.removeValue(forKey: address)?.cancel()
        devices.removeValue(forKey: address)
        let known = connected.first { $0.id == address }?.name
        connected.removeAll { $0.id == address }
        guard AppSettings.shared.bluetoothAlerts, let name = known ?? device.name, !name.isEmpty,
              shouldAnnounce(name, connected: false) else { return }
        AlertCenter.shared.post(NotchAlert(icon: Self.icon(for: device), tint: .white,
                                           title: "\(name) disconnected", tab: .home,
                                           key: "bluetooth:\(name)", duration: 2))
    }

    /// One announcement per state change per device; repeats within 20 s are dropped.
    private func shouldAnnounce(_ name: String, connected: Bool) -> Bool {
        if let last = lastAnnounced[name], last.connected == connected,
           Date().timeIntervalSince(last.at) < 20 {
            return false
        }
        lastAnnounced[name] = (connected, Date())
        return true
    }

    #if DEBUG
    /// For off-screen layout checks only.
    func previewSetConnected(_ devices: [Device]) { connected = devices }
    #endif

    private func upsert(_ device: Device) {
        if let i = connected.firstIndex(where: { $0.id == device.id }) {
            connected[i] = device
        } else {
            connected.append(device)
        }
    }

    // MARK: - Device details

    private static func icon(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("controller") || name.contains("dualsense") || name.contains("xbox") { return "gamecontroller.fill" }
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral): return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// AirPods-style per-bud levels via IOBluetoothDevice's battery properties (present on recent
    /// macOS, not in the public headers, so each is checked before use), else Apple HID devices'
    /// "BatteryPercent" from the IO registry.
    private static func levels(for device: IOBluetoothDevice) -> [Device.Level] {
        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let n = device.value(forKey: key) as? NSNumber, n.intValue > 0 else { return nil }
            return n.intValue
        }
        let pro = (device.name ?? "").lowercased().contains("pro")
        let parts: [(String, String, Int?)] = [
            ("Left", "airpod.left", level("batteryPercentLeft")),
            ("Right", "airpod.right", level("batteryPercentRight")),
            ("Case", pro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase", level("batteryPercentCase")),
        ]
        let buds = parts.compactMap { label, icon, value in value.map { Device.Level(label: label, icon: icon, percent: $0) } }
        if !buds.isEmpty { return buds }
        let name = device.name ?? "Device"
        if let single = level("batteryPercentSingle") {
            return [Device.Level(label: name, icon: icon(for: device), percent: single)]
        }
        if let hid = hidBattery(named: name) {
            return [Device.Level(label: name, icon: icon(for: device), percent: hid)]
        }
        return []
    }

    private static func hidBattery(named name: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard product == name else { continue }
            if let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                return percent
            }
        }
        return nil
    }
}
