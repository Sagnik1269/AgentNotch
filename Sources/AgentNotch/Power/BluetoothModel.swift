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
        var battery: String?    // e.g. "L 80% · R 82% · Case 60%" or "75%"
    }

    @Published private(set) var connected: [Device] = []

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date.distantPast

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard connectNotification == nil else { return }
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    private func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        connected.removeAll()
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
        // Devices already connected at start are reported immediately: list them, don't announce.
        let announce = Date().timeIntervalSince(startedAt) > 3
        var entry = Device(id: address, name: device.name ?? "Bluetooth device", icon: Self.icon(for: device))
        upsert(entry)
        // Battery levels are filled in a moment after the link comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + (announce ? 2.5 : 0.5)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                entry.battery = Self.battery(for: device)
                self.upsert(entry)
                guard announce, AppSettings.shared.bluetoothAlerts else { return }
                AlertCenter.shared.post(NotchAlert(icon: entry.icon, tint: .blue,
                                                   title: "\(entry.name) connected",
                                                   subtitle: entry.battery ?? "", tab: .home))
            }
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        let name = connected.first { $0.id == address }?.name ?? device.name ?? "Bluetooth device"
        connected.removeAll { $0.id == address }
        guard AppSettings.shared.bluetoothAlerts else { return }
        AlertCenter.shared.post(NotchAlert(icon: Self.icon(for: device), tint: .white,
                                           title: "\(name) disconnected", tab: .home))
    }

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
    private static func battery(for device: IOBluetoothDevice) -> String? {
        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let n = device.value(forKey: key) as? NSNumber, n.intValue > 0 else { return nil }
            return n.intValue
        }
        let parts = [("L", level("batteryPercentLeft")), ("R", level("batteryPercentRight")),
                     ("Case", level("batteryPercentCase"))]
            .compactMap { label, value in value.map { "\(label) \($0)%" } }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let single = level("batteryPercentSingle") { return "\(single)%" }
        if let name = device.name, let hid = hidBattery(named: name) { return "\(hid)%" }
        return nil
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
