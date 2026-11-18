import AppKit

/// One countdown timer. Time is kept as an end date, so it stays exact across sleep and redraws.
@MainActor
final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    @Published private(set) var state: State = .idle
    /// Length of the current (or next) countdown, seconds.
    @Published private(set) var duration: TimeInterval = 5 * 60

    private var finishWork: DispatchWorkItem?

    var isActive: Bool { state != .idle }
    var isRunning: Bool { if case .running = state { true } else { false } }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch state {
        case .idle: duration
        case .running(let end): max(end.timeIntervalSince(date), 0)
        case .paused(let remaining): remaining
        }
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    // MARK: - Controls

    func start(minutes: Double) {
        duration = minutes * 60
        run(for: duration)
    }

    func start() { run(for: duration) }

    func pause() {
        guard case .running = state else { return }
        state = .paused(remaining: remaining())
        finishWork?.cancel()
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        run(for: remaining)
    }

    func cancel() {
        finishWork?.cancel()
        state = .idle
    }

    /// Adds (or removes) time; when idle it changes the length of the next countdown.
    func adjust(byMinutes minutes: Double) {
        let delta = minutes * 60
        switch state {
        case .idle:
            duration = min(max(duration + delta, 60), 24 * 3600)
        case .running:
            let left = remaining() + delta
            guard left > 1 else { return }
            duration = max(duration + delta, left)
            run(for: left)
        case .paused(let remaining):
            let left = remaining + delta
            guard left > 1 else { return }
            duration = max(duration + delta, left)
            state = .paused(remaining: left)
        }
    }

    private func run(for seconds: TimeInterval) {
        state = .running(end: Date().addingTimeInterval(seconds))
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish() {
        // asyncAfter can fire early after sleep; re-check against the wall clock.
        if case .running(let end) = state, end.timeIntervalSinceNow > 0.5 {
            run(for: end.timeIntervalSinceNow)
            return
        }
        state = .idle
        AlertCenter.shared.post(NotchAlert(icon: "timer", tint: .orange, title: "Time's up",
                                           subtitle: "\(Self.format(duration)) timer", tab: .timer,
                                           key: "timer", duration: 5))
        let sound = NSSound(named: "Glass")
        sound?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sound?.stop(); sound?.play() }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
