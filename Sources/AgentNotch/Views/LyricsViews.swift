import SwiftUI

/// Scrolling lyrics for the Media tab: the sung line stays centered and lit; click a line to seek.
struct LyricsPanel: View {
    let accent: Color
    @ObservedObject private var lyrics = LyricsModel.shared

    var body: some View {
        Group {
            switch lyrics.state {
            case .synced:
                syncedList
                    .overlay(alignment: .top) {
                        if let delta = lyrics.lyrics?.versionDelta, lyrics.songOffset == 0 {
                            badge("Lyrics are for a \(delta < 0 ? "shorter" : "longer") version · ⌥-click the line you hear")
                        }
                    }
            case .plain:
                ScrollView(showsIndicators: false) {
                    Text(lyrics.lyrics?.plain ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .overlay(alignment: .topTrailing) { badge("Not time-synced") }
            case .loading:
                message(icon: nil, "Finding lyrics…")
            case .instrumental:
                message(icon: "pianokeys", "Instrumental")
            case .notFound:
                message(icon: "text.badge.xmark", "No lyrics found for this track")
            case .failed:
                VStack(spacing: 8) {
                    message(icon: "wifi.exclamationmark", "Couldn't reach LRCLIB")
                    Button("Try again") { lyrics.retry() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            case .idle, .off:
                message(icon: "quote.bubble", "Lyrics show up here")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private var syncedList: some View {
        let lines = lyrics.lyrics?.lines ?? []
        let current = lyrics.currentIndex
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    Color.clear.frame(height: 40)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LyricRow(text: line.text, isCurrent: index == current,
                                 isPast: (current ?? -1) > index, accent: accent,
                                 onTap: {
                                     if NSEvent.modifierFlags.contains(.option) {
                                         lyrics.syncLine(index)
                                     } else {
                                         lyrics.seek(toLine: index)
                                     }
                                 },
                                 onSync: { lyrics.syncLine(index) })
                        .id(index)
                    }
                    Color.clear.frame(height: 40)
                }
            }
            .onAppear { proxy.scrollTo(current ?? 0, anchor: .center) }
            .onChange(of: current) { _, newValue in
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newValue ?? 0, anchor: .center)
                }
            }
        }
    }

    private func message(icon: String?, _ text: String) -> some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.45))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .padding(.top, 14)
    }
}

private struct LyricRow: View {
    let text: String
    let isCurrent: Bool
    let isPast: Bool
    let accent: Color
    let onTap: () -> Void
    let onSync: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if text.isEmpty {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
            } else {
                Text(text)
            }
        }
        .font(.system(size: isCurrent ? 16 : 13, weight: isCurrent ? .bold : .semibold, design: .rounded))
        .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(hovering ? 0.7 : (isPast ? 0.28 : 0.4))))
        .shadow(color: isCurrent ? accent.opacity(0.6) : .clear, radius: 8)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Sync: this line is playing now", action: onSync)
            Button("Play from this line", action: onTap)
        }
        .onHover { hovering = $0 }
        .help("Click to play from here · ⌥-click when you hear this line to fix the timing")
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCurrent)
    }
}

/// Per-song timing controls: nudge earlier/later, shows the current correction, reset.
struct LyricsSyncControls: View {
    @ObservedObject private var lyrics = LyricsModel.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            step("minus", -0.5, help: "Lyrics are ahead: show lines later")
            Text(label)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(lyrics.songOffset == 0 ? 0.4 : 0.8))
                .frame(minWidth: 40)
            step("plus", 0.5, help: "Lyrics are behind: show lines earlier")
            if lyrics.songOffset != 0 {
                Button { lyrics.resetSongOffset() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("Reset this song's timing")
            }
        }
        .disabled(lyrics.state != .synced)
        .opacity(lyrics.state == .synced ? 1 : 0.4)
    }

    private var label: String {
        lyrics.songOffset == 0 ? "in sync" : String(format: "%+.1fs", lyrics.songOffset)
    }

    private func step(_ icon: String, _ delta: Double, help: String) -> some View {
        Button { lyrics.nudgeSong(by: delta) } label: {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.75))
        .help(help)
    }
}

/// The lyrics toggle in the Media tab. Turning it on for the first time also enables live lyrics.
struct LyricsToggleButton: View {
    @Binding var showing: Bool
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false

    var body: some View {
        let active = showing && settings.liveLyrics
        Button {
            if active {
                showing = false
            } else {
                settings.liveLyrics = true
                showing = true
            }
        } label: {
            Image(systemName: active ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : (hovering ? 0.85 : 0.55)))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(active || hovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active ? "Hide lyrics" : "Show live lyrics (from lrclib.net)")
    }
}
