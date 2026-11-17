import Foundation

enum HUDKind: Equatable {
    case volume
    case brightness
}

struct HUDState: Equatable {
    var kind: HUDKind
    var value: Float      // 0...1
    var muted: Bool = false

    var icon: String {
        switch kind {
        case .volume:
            if muted || value <= 0.001 { return "speaker.slash.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// The transient volume/brightness indicator shown in the closed notch.
@MainActor
final class HUDModel: ObservableObject {
    static let shared = HUDModel()

    @Published private(set) var state: HUDState?
    private var hideTask: DispatchWorkItem?

    func show(_ newState: HUDState) {
        state = newState
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.state = nil }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
    }
}
