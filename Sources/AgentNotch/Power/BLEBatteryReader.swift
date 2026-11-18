import CoreBluetooth
import Foundation
import os

private let bleLog = Logger(subsystem: "dev.agentnotch.AgentNotch", category: "ble")

/// Reads battery levels from Bluetooth LE devices that macOS doesn't report itself — e.g. Logitech
/// mice, mechanical keyboards — via the standard GATT Battery Service (0x180F / Battery Level 0x2A19).
///
/// Only devices already connected to this Mac are read; nothing is scanned or paired. Uses the same
/// Bluetooth permission as the rest of the Bluetooth features.
@MainActor
final class BLEBatteryReader: NSObject, ObservableObject {
    static let shared = BLEBatteryReader()

    struct Reading: Identifiable, Equatable {
        let id: UUID
        let name: String
        var percent: Int?
    }

    @Published private(set) var devices: [Reading] = []

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var refreshTimer: Timer?

    /// Name normalized for matching the same device across Bluetooth APIs.
    static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let hidService = CBUUID(string: "1812")

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard central == nil else { return }
            bleLog.notice("starting")
            central = CBCentralManager(delegate: self, queue: .main)
            let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            if let central { peripherals.values.forEach { central.cancelPeripheralConnection($0) } }
            peripherals.removeAll()
            central = nil
            devices.removeAll()
        }
    }

    #if DEBUG
    func previewSet(_ readings: [Reading]) { devices = readings }
    #endif

    /// Re-checks which devices are connected and re-reads their levels.
    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService, Self.hidService])
        bleLog.notice("connected: \(connected.map { $0.name ?? "?" }.joined(separator: ", "), privacy: .public)")
        let ids = Set(connected.map(\.identifier))
        // Forget devices that went away.
        for id in peripherals.keys where !ids.contains(id) { peripherals[id] = nil }
        devices.removeAll { !ids.contains($0.id) }

        for p in connected {
            if peripherals[p.identifier] == nil {
                peripherals[p.identifier] = p
                p.delegate = self
            }
            if !devices.contains(where: { $0.id == p.identifier }) {
                devices.append(Reading(id: p.identifier, name: p.name ?? "Bluetooth device", percent: nil))
            }
            // The device is connected to macOS already; this opens our app's own link to it.
            if p.state == .connected {
                readBattery(p)
            } else {
                central.connect(p)
            }
        }
    }

    private func readBattery(_ p: CBPeripheral) {
        if let ch = p.services?.first(where: { $0.uuid == Self.batteryService })?
            .characteristics?.first(where: { $0.uuid == Self.batteryLevel }) {
            p.readValue(for: ch)
        } else {
            p.discoverServices([Self.batteryService])
        }
    }

    private func update(_ id: UUID, name: String?, percent: Int?) {
        if let i = devices.firstIndex(where: { $0.id == id }) {
            if let name { devices[i] = Reading(id: id, name: name, percent: percent ?? devices[i].percent) }
            else if let percent { devices[i].percent = percent }
        }
    }
}

extension BLEBatteryReader: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bleLog.notice("state \(central.state.rawValue, privacy: .public) auth \(CBManager.authorization.rawValue, privacy: .public)")
            if central.state == .poweredOn { refresh() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { readBattery(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
                bleLog.notice("\(peripheral.name ?? "device", privacy: .public) has no battery service")
                return
            }
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let ch = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first else {
                if let error { bleLog.notice("read failed \(peripheral.name ?? "device", privacy: .public): \(error.localizedDescription, privacy: .public)") }
                return
            }
            let percent = min(Int(byte), 100)
            bleLog.notice("battery \(peripheral.name ?? "device", privacy: .public) = \(percent, privacy: .public)%")
            update(peripheral.identifier, name: peripheral.name, percent: percent)
        }
    }
}
