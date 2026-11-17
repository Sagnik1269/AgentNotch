import AppKit
import ApplicationServices

/// Intercepts the volume and brightness keys so the notch HUD replaces the system one.
/// Needs Accessibility permission (an event tap that can swallow events).
@MainActor
final class MediaKeyInterceptor: ObservableObject {
    static let shared = MediaKeyInterceptor()

    @Published private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustPoll: Timer?

    // NX_KEYTYPE_* codes carried in NX_SYSDEFINED events (IOKit/hidsystem/ev_keymap.h).
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private static let systemDefinedType = CGEventType(rawValue: 14)! // NX_SYSDEFINED
    private static let mediaKeySubtype: Int16 = 8                    // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    // MARK: - Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if the app isn't trusted yet.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    /// Starts intercepting now if trusted; otherwise keeps checking until permission is granted.
    func start() {
        guard tap == nil else { return }
        if Self.isTrusted {
            installTap()
        } else {
            trustPoll?.invalidate()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.isTrusted else { return }
                    self.trustPoll?.invalidate()
                    self.trustPoll = nil
                    self.installTap()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            trustPoll = timer
        }
    }

    func stop() {
        trustPoll?.invalidate()
        trustPoll = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func installTap() {
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("AgentNotch: could not create media key event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isRunning = true
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow taps; turn ourselves back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemDefinedType,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.mediaKeySubtype,
              let key = Key(rawValue: (ns.data1 & 0xFFFF_0000) >> 16)
        else { return Unmanaged.passUnretained(event) }

        let flags = ns.data1 & 0x0000_FFFF
        let isKeyDown = ((flags & 0xFF00) >> 8) == 0x0A
        let modifiers = ns.modifierFlags.intersection([.option, .shift, .control, .command])

        // Option alone opens the related System Settings pane; leave that to macOS.
        if modifiers == .option { return Unmanaged.passUnretained(event) }
        let fine = modifiers == [.option, .shift]

        let handled: Bool
        switch key {
        case .soundUp, .soundDown, .mute:
            handled = handleVolume(key, keyDown: isKeyDown, fine: fine)
        case .brightnessUp, .brightnessDown:
            handled = handleBrightness(up: key == .brightnessUp, keyDown: isKeyDown, fine: fine)
        }
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns false to let macOS handle the key (e.g. an HDMI output with no software volume).
    private func handleVolume(_ key: Key, keyDown: Bool, fine: Bool) -> Bool {
        let volume = VolumeController.shared
        guard volume.canSetVolume else { return false }
        guard keyDown else { return true }

        switch key {
        case .mute:
            volume.setMuted(!volume.isMuted)
        default:
            let next = Self.step(volume.volume, up: key == .soundUp, fine: fine)
            if volume.isMuted && key == .soundUp { volume.setMuted(false) }
            volume.setVolume(next)
        }
        HUDModel.shared.show(HUDState(kind: .volume, value: volume.volume, muted: volume.isMuted))
        return true
    }

    private func handleBrightness(up: Bool, keyDown: Bool, fine: Bool) -> Bool {
        let display = BrightnessController.shared
        guard let current = display.brightness else { return false }
        guard keyDown else { return true }
        let next = Self.step(current, up: up, fine: fine)
        display.setBrightness(next)
        HUDModel.shared.show(HUDState(kind: .brightness, value: next))
        return true
    }

    /// macOS-style steps: 16 per full range, or 64 with Option+Shift.
    private static func step(_ value: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let index = (value * steps).rounded() + (up ? 1 : -1)
        return min(max(index / steps, 0), 1)
    }
}
