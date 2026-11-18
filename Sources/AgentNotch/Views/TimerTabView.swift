import SwiftUI

/// Timer: a ring with the time left, presets, and controls.
struct TimerTabView: View {
    @ObservedObject private var timer = TimerModel.shared
    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        HStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: timer.isActive ? 1 - timer.progress(at: context.date) : 1)
                        .stroke(timer.isRunning ? NotchAlert.Tint.orange.color : .white.opacity(0.6),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: timer.progress(at: context.date))
                    VStack(spacing: 2) {
                        Text(TimerModel.format(timer.remaining(at: context.date)))
                            .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        Chip(title: minutes >= 60 ? "\(Int(minutes / 60)) h" : "\(Int(minutes)) min",
                             highlighted: !timer.isActive && timer.duration == minutes * 60) {
                            timer.start(minutes: minutes)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Chip(title: "−1 min") { timer.adjust(byMinutes: -1) }
                    Chip(title: "+1 min") { timer.adjust(byMinutes: 1) }
                    Spacer(minLength: 0)
                    if timer.isActive {
                        RoundButton(icon: "xmark", tint: .white.opacity(0.15)) { timer.cancel() }
                            .help("Cancel")
                    }
                    RoundButton(icon: primaryIcon, tint: NotchAlert.Tint.orange.color) { primaryAction() }
                        .help(primaryHelp)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private var statusText: String {
        switch timer.state {
        case .idle: "Ready"
        case .running(let end): "Ends \(end.formatted(date: .omitted, time: .shortened))"
        case .paused: "Paused"
        }
    }

    private var primaryIcon: String {
        timer.isRunning ? "pause.fill" : "play.fill"
    }

    private var primaryHelp: String {
        switch timer.state {
        case .idle: "Start"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    private func primaryAction() {
        switch timer.state {
        case .idle: timer.start()
        case .running: timer.pause()
        case .paused: timer.resume()
        }
    }
}

private struct Chip: View {
    let title: String
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(highlighted ? 0.22 : (hovering ? 0.14 : 0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
    }
}

private struct RoundButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
