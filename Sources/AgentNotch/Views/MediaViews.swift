import SwiftUI

/// Full player for the Media tab.
struct MediaTabView: View {
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        if media.hasMedia {
            HStack(spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(image: media.artwork, side: 112, cornerRadius: 14)
                        .shadow(color: Color(nsColor: media.accentColor).opacity(0.35), radius: 14)
                    if let icon = media.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                            .offset(x: 6, y: 6)
                            .help(media.appName ?? "")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(media.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text(media.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VisualizerBars(color: Color(nsColor: media.accentColor))
                            .frame(width: 22, height: 16)
                    }

                    Scrubber()

                    PlaybackControls(size: .large)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PlaceholderTabView(icon: "music.note", title: "Nothing playing",
                               detail: "Play something in Music, Spotify, a browser or any media app.")
        }
    }
}

/// Compact now-playing row for the Home tab.
struct MiniPlayerView: View {
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(image: media.artwork, side: 34, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.hasMedia ? media.title : "Nothing playing")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(media.hasMedia ? media.artist : "Media controls show up here")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if media.hasMedia {
                PlaybackControls(size: .small)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

struct PlaybackControls: View {
    enum Size { case small, large }
    let size: Size
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        HStack(spacing: size == .large ? 22 : 6) {
            ControlButton(systemName: "backward.fill", pointSize: size == .large ? 15 : 11) { media.previous() }
            ControlButton(systemName: media.isPlaying ? "pause.fill" : "play.fill",
                          pointSize: size == .large ? 22 : 13) { media.togglePlayPause() }
            ControlButton(systemName: "forward.fill", pointSize: size == .large ? 15 : 11) { media.next() }
        }
    }
}

private struct ControlButton: View {
    let systemName: String
    let pointSize: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: pointSize, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: pointSize * 1.9, height: pointSize * 1.7)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Seekable progress bar with elapsed / remaining time.
struct Scrubber: View {
    @ObservedObject private var media = NowPlayingModel.shared
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = media.duration
            let elapsed = dragValue ?? media.elapsed(at: context.date)
            let progress = duration > 0 ? elapsed / duration : 0

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * progress)
                    }
                    .frame(height: hovering || dragValue != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard duration > 0 else { return }
                                dragValue = min(max(g.location.x / geo.size.width, 0), 1) * duration
                            }
                            .onEnded { _ in
                                if let value = dragValue { media.seek(to: value) }
                                dragValue = nil
                            }
                    )
                }
                .frame(height: 10)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)

                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text(duration > 0 ? "-" + Self.format(max(duration - elapsed, 0)) : "--:--")
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .disabled(media.duration <= 0)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Artwork in a fixed square box. Any aspect ratio (square album art, 16:9 video thumbnails,
/// tall posters) is scaled to cover the box and center-cropped, so the box never changes size.
struct ArtworkView: View {
    let image: NSImage?
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let box = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        // The box defines layout; the image sits in an overlay so its natural size can't leak out.
        Color.white.opacity(0.08)
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: max(side * 0.36, 9), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .clipShape(box)
            .overlay(box.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .animation(.easeInOut(duration: 0.2), value: image)
    }
}

/// Equalizer bars driven by live audio: bass, low-mids, high-mids, treble (left to right).
/// With no signal (paused, silent, or permission denied) they rest as dots.
///
/// Drawn with Core Animation layers updated straight from the audio callback, so 30 updates a second
/// never touch SwiftUI's layout (which made the whole notch panel re-lay-out each frame).
struct VisualizerBars: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> SpectrumBarsView {
        SpectrumBarsView()
    }

    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.color = NSColor(color)
    }

    static func dismantleNSView(_ view: SpectrumBarsView, coordinator: ()) {
        view.detach()
    }
}

final class SpectrumBarsView: NSView {
    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }

    private var bars: [CALayer] = []
    private var levels: [Float] = [0, 0, 0, 0]
    private var token: UUID?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        bars = (0..<4).map { _ in
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            return bar
        }
        token = AudioSpectrumModel.shared.addObserver { [weak self] levels in
            self?.levels = levels
            self?.layoutBars(animated: true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func detach() {
        if let token { AudioSpectrumModel.shared.removeObserver(token) }
        token = nil
    }

    override func layout() {
        super.layout()
        layoutBars(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        bars.forEach { $0.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    private func layoutBars(animated: Bool) {
        let count = CGFloat(bars.count)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let spacing = bounds.width * 0.14
        let barWidth = (bounds.width - spacing * (count - 1)) / count

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(1.0 / 30)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, bar) in bars.enumerated() {
            let level = CGFloat(i < levels.count ? levels[i] : 0)
            let height = max(barWidth, bounds.height * level)
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(x: CGFloat(i) * (barWidth + spacing),
                               y: (bounds.height - height) / 2,
                               width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
