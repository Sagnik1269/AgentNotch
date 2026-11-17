import AppKit
import CoreAudio

/// Live frequency-band levels from the Mac's audio output, for the visualizer.
/// The tap only runs while something is playing and the visualizer is enabled.
@MainActor
final class AudioSpectrumModel: ObservableObject {
    static let shared = AudioSpectrumModel()

    enum Status: Equatable {
        case off
        case running
        case unsupported            // macOS older than 14.2
        case failed(String)
    }

    /// Deliberately not @Published: it changes 30×/s, and publishing would re-render every SwiftUI
    /// view observing this model. Visualizers subscribe with `addObserver` instead.
    private(set) var levels: [Float] = [0, 0, 0, 0] {
        didSet { observers.values.forEach { $0(levels) } }
    }
    @Published private(set) var status: Status = .off

    private var observers: [UUID: ([Float]) -> Void] = [:]

    func addObserver(_ block: @escaping ([Float]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        block(levels)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private var tap: AnyObject?
    private var wantsActive = false
    private var stopTask: DispatchWorkItem?
    private var outputListener: AudioObjectPropertyListenerBlock?

    private init() {
        // The tap is clocked by the output device; rebuild it when the output changes.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .running else { return }
                self.stopTap()
                self.startTap()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        outputListener = listener
    }

    /// Starts immediately; stops after a short grace period (so pause → play doesn't churn devices).
    func setActive(_ active: Bool) {
        wantsActive = active
        stopTask?.cancel()
        if active {
            startTap()
        } else {
            let task = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.wantsActive else { return }
                    self.stopTap()
                }
            }
            stopTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTap() {
        guard tap == nil else { return }
        guard #available(macOS 14.2, *) else {
            status = .unsupported
            return
        }
        let newTap = SystemAudioTap()
        newTap.onLevels = { [weak self] levels in
            guard let self, self.tap != nil else { return }
            self.levels = levels
        }
        do {
            try newTap.start()
            tap = newTap
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
            NSLog("AgentNotch: audio tap failed: \(error.localizedDescription)")
        }
    }

    private func stopTap() {
        if #available(macOS 14.2, *), let current = tap as? SystemAudioTap {
            current.stop()
        }
        tap = nil
        if status == .running { status = .off }
        levels = [0, 0, 0, 0]
    }
}
