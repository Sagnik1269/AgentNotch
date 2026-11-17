import CoreAudio
import Foundation

/// Reads and writes the default output device's volume and mute state via CoreAudio.
@MainActor
final class VolumeController {
    static let shared = VolumeController()

    /// Called on any volume/mute change, whatever caused it (keys, Control Center, another app).
    var onChange: ((Float, Bool) -> Void)?

    private var device: AudioDeviceID = kAudioObjectUnknown
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume (AudioToolbox).
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: virtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        attachToDefaultDevice()
    }

    // MARK: - State

    var canSetVolume: Bool {
        isSettable(Self.volumeAddress)
    }

    var volume: Float {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        guard device != kAudioObjectUnknown,
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    var isMuted: Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.muteAddress
        guard device != kAudioObjectUnknown,
              AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    func setVolume(_ newValue: Float) {
        var value = Float32(min(max(newValue, 0), 1))
        var address = Self.volumeAddress
        guard device != kAudioObjectUnknown else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if value > 0 && isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.muteAddress
        guard device != kAudioObjectUnknown, isSettable(Self.muteAddress) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: - Device tracking

    private func isSettable(_ addr: AudioObjectPropertyAddress) -> Bool {
        var address = addr
        var settable: DarwinBoolean = false
        guard device != kAudioObjectUnknown,
              AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func attachToDefaultDevice() {
        for (addr, block) in deviceListeners {
            var address = addr
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        deviceListeners.removeAll()

        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultOutputAddress
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else { return }

        for addr in [Self.volumeAddress, Self.muteAddress] {
            var a = addr
            guard AudioObjectHasProperty(id, &a) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange?(self.volume, self.isMuted)
                }
            }
            if AudioObjectAddPropertyListenerBlock(id, &a, .main, block) == noErr {
                deviceListeners.append((addr, block))
            }
        }
    }
}
