import SwiftUI

/// Root view inside the notch panel. Draws the shape at the top-center and morphs it between
/// idle, live activities (HUD, now playing) and the open dashboard.
struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hud = HUDModel.shared
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var alerts = AlertCenter.shared
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var lyrics = LyricsModel.shared
    @ObservedObject private var statusPops = StatusPopModel.shared

    var body: some View {
        let activity = ClosedActivity.current(settings: settings, hud: hud, media: media,
                                              alerts: alerts, agents: agents, lyrics: lyrics)
        let size = vm.shapeSize(for: activity)
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius(for: activity))

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            if vm.isOpen {
                ExpandedNotchView(vm: vm)
                    .padding(.horizontal, vm.openTopRadius + 16)
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.94, anchor: .top))
                                .animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))
                        )
                    )
            } else if activity != .idle {
                ClosedActivityView(vm: vm, activity: activity)
                    .padding(.horizontal, vm.closedTopRadius)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .scaleEffect(vm.isHovering && !vm.isOpen ? 1.05 : 1, anchor: .top)
        .shadow(color: .black.opacity(vm.isOpen ? 0.5 : 0), radius: 16, y: 6)
        .onTapGesture {
            if !vm.isOpen { vm.onRequestOpen?() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: vm.isOpen)
        // Alerts and status pops animate with their own curve (slow in, quick out) set where they're
        // posted; everything else (HUD, now playing, agents) keeps the spring.
        .transaction(value: activity.layoutKey) { t in
            if t.animation == nil { t.animation = .spring(response: 0.38, dampingFraction: 0.8) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vm.isHovering)
        .environment(\.colorScheme, .dark)
    }
}

/// Content for the closed notch's wings (left/right of the camera) and the peek row below.
struct ClosedActivityView: View {
    @ObservedObject var vm: NotchViewModel
    let activity: ClosedActivity
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: wingWidth)
                Spacer(minLength: vm.notchSize.width)
                rightWing.frame(width: wingWidth)
            }
            .frame(height: vm.notchSize.height)

            if case .nowPlaying(row: .peek) = activity {
                peekRow
                    .frame(height: vm.peekRowHeight)
                    .transition(.opacity)
            } else if case .nowPlaying(row: .lyric) = activity {
                LyricLineRow(accent: Color(nsColor: media.accentColor))
                    .frame(height: vm.lyricRowHeight)
                    .transition(.opacity)
            } else if case .alert(let alert) = activity {
                alertRow(alert)
                    .frame(height: vm.alertRowHeight)
                    .id(alert.id)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }

    private func alertRow(_ alert: NotchAlert) -> some View {
        VStack(spacing: 1) {
            Text(alert.title)
                .font(.system(size: 12, weight: .semibold))
            if !alert.subtitle.isEmpty {
                Text(alert.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private var wingWidth: CGFloat {
        switch activity {
        case .hud, .status: return vm.hudWingWidth
        default: break
        }
        return vm.mediaWingWidth
    }

    private var artSide: CGFloat { max(vm.notchSize.height - 12, 16) }

    @ViewBuilder private var leftWing: some View {
        switch activity {
        case .hud(let state):
            // Pinned to the outer edge; the same inset is used for the slider on the right.
            Image(systemName: state.icon)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, vm.hudEdgeInset)
        case .status(let pop):
            Image(systemName: pop.icon)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(pop.tint.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, vm.hudEdgeInset)
        case .nowPlaying:
            ArtworkView(image: media.artwork, side: artSide, cornerRadius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .alert(let alert):
            Image(systemName: alert.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(alert.tint.color)
                .frame(maxWidth: .infinity, alignment: .center)
        case .agents(let waiting, _):
            AgentGlyph(waiting: waiting > 0)
                .frame(maxWidth: .infinity, alignment: .center)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch activity {
        case .hud(let state):
            HStack(spacing: 6) {
                LevelBar(value: CGFloat(state.muted ? 0 : state.value))
                    .frame(width: 48, height: 5)
                Text("\(Int((state.muted ? 0 : state.value) * 100))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, vm.hudEdgeInset)
        case .status(let pop):
            Text(pop.text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(pop.tint.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, vm.hudEdgeInset)
        case .nowPlaying:
            Group {
                if settings.showVisualizer {
                    VisualizerBars(color: Color(nsColor: media.accentColor))
                        .frame(width: 18, height: 14)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: media.accentColor))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .alert:
            EmptyView()
        case .agents(let waiting, let working):
            let count = waiting > 0 ? waiting : working
            Group {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(waiting > 0 ? NotchAlert.Tint.orange.color : .white.opacity(0.8))
                } else if waiting > 0 {
                    Circle().fill(NotchAlert.Tint.orange.color).frame(width: 7, height: 7)
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .idle:
            EmptyView()
        }
    }

    private var peekRow: some View {
        HStack(spacing: 6) {
            Text(media.title).font(.system(size: 12, weight: .semibold))
            if !media.artist.isEmpty {
                Text(media.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}

/// The current lyric line under the closed notch. Lines cross-fade and slide up as they change.
struct LyricLineRow: View {
    let accent: Color
    @ObservedObject private var lyrics = LyricsModel.shared
    @ObservedObject private var statusPops = StatusPopModel.shared

    var body: some View {
        let line = lyrics.currentLine
        let text = line?.text ?? ""
        ZStack {
            Group {
                if text.isEmpty {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.8))
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                } else {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.tail)
                }
            }
            .id(lyrics.currentIndex ?? -1)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity.combined(with: .offset(y: -8))
            ))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.28), value: lyrics.currentIndex)
    }
}

/// Agent status mark: a gently pulsing sparkle while working, an orange bubble when it needs you.
struct AgentGlyph: View {
    let waiting: Bool

    var body: some View {
        Image(systemName: waiting ? "exclamationmark.bubble.fill" : "sparkle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(waiting ? NotchAlert.Tint.orange.color : Color(red: 0.85, green: 0.55, blue: 0.4))
            .symbolEffect(.pulse, options: .repeating, isActive: true)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Thin horizontal level indicator used by the HUD.
struct LevelBar: View {
    let value: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white)
                    .frame(width: max(geo.size.width * min(max(value, 0), 1), value > 0 ? geo.size.height : 0))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
    }
}
