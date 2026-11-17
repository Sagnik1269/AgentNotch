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
                                 isPast: (current ?? -1) > index, accent: accent) {
                            lyrics.seek(toLine: index)
                        }
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
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCurrent)
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
