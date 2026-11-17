import Combine
import Foundation

/// Lyrics for the current track and which line is being sung right now.
///
/// Line changes are scheduled for the exact moment the next line starts (no polling); every
/// play/pause/seek/track update from the media bridge re-anchors the schedule.
@MainActor
final class LyricsModel: ObservableObject {
    static let shared = LyricsModel()

    enum State: Equatable {
        case off            // toggle disabled
        case idle           // nothing playing
        case loading
        case synced
        case plain          // lyrics exist but have no timestamps
        case instrumental
        case notFound
        case failed
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lyrics: Lyrics?
    /// Index into `lyrics.lines` of the line being sung; nil before the first line.
    @Published private(set) var currentIndex: Int?

    private let service = LyricsService()
    private let media = NowPlayingModel.shared
    private let settings = AppSettings.shared
    private var trackKey = ""
    private var loadTask: Task<Void, Never>?
    private var tick: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }
        // @Published fires before the value is stored; hop to the next main-loop turn to read it.
        media.$timelineRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.mediaChanged() }
            .store(in: &cancellables)
        settings.$liveLyrics
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.trackKey = ""
                self?.mediaChanged()
            }
            .store(in: &cancellables)
        settings.$lyricsOffset
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resync() }
            .store(in: &cancellables)
        mediaChanged()
    }

    /// The line currently on screen, if lyrics are synced.
    var currentLine: Lyrics.Line? {
        guard state == .synced, let i = currentIndex, let lines = lyrics?.lines, lines.indices.contains(i) else { return nil }
        return lines[i]
    }

    /// Seeks playback to the start of a line (accounting for the timing nudge).
    func seek(toLine index: Int) {
        guard let lines = lyrics?.lines, lines.indices.contains(index) else { return }
        media.seek(to: max(lines[index].time - settings.lyricsOffset, 0) + 0.05)
    }

    /// Clears a failed lookup so it's tried again.
    func retry() {
        trackKey = ""
        mediaChanged()
    }

    // MARK: - Track changes

    private func mediaChanged() {
        guard settings.liveLyrics else {
            reset(to: .off)
            trackKey = ""
            return
        }
        guard media.hasMedia else {
            reset(to: .idle)
            trackKey = ""
            return
        }
        // Duration is part of the identity: it often arrives a moment after the title.
        let key = "\(media.title)\u{1F}\(media.artist)\u{1F}\(Int(media.duration.rounded()))"
        if key != trackKey {
            trackKey = key
            load()
        }
        resync()
    }

    private func reset(to newState: State) {
        loadTask?.cancel()
        tick?.cancel()
        if state != newState { state = newState }
        if lyrics != nil { lyrics = nil }
        if currentIndex != nil { currentIndex = nil }
    }

    private func load() {
        reset(to: .loading)
        let query = LyricsService.Query(title: media.title, artist: media.artist,
                                        album: media.album, duration: media.duration)
        let key = trackKey
        let service = service
        loadTask = Task { [weak self] in
            // Let metadata settle (title → artist → duration often arrive in separate updates).
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let outcome: Result<LyricsService.Result, Error>
            do { outcome = .success(try await service.lyrics(for: query)) } catch { outcome = .failure(error) }
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: Result<LyricsService.Result, Error>) {
        switch outcome {
        case .failure(let error):
            NSLog("AgentNotch: lyrics lookup failed: \(error.localizedDescription)")
            state = .failed
        case .success(.notFound):
            state = .notFound
        case .success(.found(let found)):
            lyrics = found
            state = found.isSynced ? .synced : (found.plain != nil ? .plain : .instrumental)
            resync()
        }
    }

    // MARK: - Line timing

    private func resync() {
        tick?.cancel()
        guard state == .synced, let lines = lyrics?.lines, !lines.isEmpty else { return }

        let t = media.elapsed() + settings.lyricsOffset
        let index = Self.lineIndex(at: t, in: lines)
        if index != currentIndex { currentIndex = index }

        let rate = media.playbackRate
        let next = (index ?? -1) + 1
        guard rate > 0, lines.indices.contains(next) else { return }
        let delay = max((lines[next].time - t) / rate, 0) + 0.01
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resync() }
        }
        tick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Last line whose start time is ≤ t (binary search).
    static func lineIndex(at t: Double, in lines: [Lyrics.Line]) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
