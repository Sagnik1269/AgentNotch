import SwiftUI

/// A brief wing-style status in the closed notch (e.g. "charging 54%"), like the volume HUD.
struct StatusPop: Equatable {
    var icon: String
    var text: String
    var tint: NotchAlert.Tint = .white
}

@MainActor
final class StatusPopModel: ObservableObject {
    static let shared = StatusPopModel()

    @Published private(set) var current: StatusPop?
    private var hideTask: DispatchWorkItem?

    func show(_ pop: StatusPop, for seconds: Double = 2) {
        let appearing = current == nil
        if appearing {
            withAnimation(.notchPopIn) { current = pop }
        } else {
            current = pop
        }
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.notchPopOut) { self?.current = nil } }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + (appearing ? 0.55 : 0), execute: task)
    }
}
