import AppKit
import Combine
import CoreImage

/// Current now-playing state from MediaRemote, plus playback commands.
@MainActor
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor: NSColor = .white
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var appName: String?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appBundleID: String?

    /// True for a few seconds after the track changes, so the closed notch can preview it.
    @Published private(set) var isPeeking = false

    /// Bumped whenever the track, play state or position changes (bridge update, seek, toggle),
    /// so time-synced consumers like lyrics can re-anchor without polling.
    @Published private(set) var timelineRevision = 0

    private var elapsedAtSample: Double = 0
    private var sampleDate = Date()
    private var rate: Double = 0
    private var lastPID: Int32 = 0
    private var peekTask: DispatchWorkItem?
    private let service = NowPlayingService()

    var hasMedia: Bool { !title.isEmpty }

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private init() {
        service.onUpdate = { [weak self] update in self?.apply(update) }
    }

    func start() { service.start() }
    func stop() { service.stop() }

    /// Effective playback speed (0 while paused).
    var playbackRate: Double { isPlaying ? max(rate, 0) : 0 }

    /// Elapsed time interpolated from the last sample while playing.
    func elapsed(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let value = isPlaying ? elapsedAtSample + date.timeIntervalSince(sampleDate) * max(rate, 0) : elapsedAtSample
        return min(max(value, 0), duration)
    }

    // MARK: - Commands (optimistic UI updates, then the bridge confirms)

    func togglePlayPause() {
        let now = Date()
        elapsedAtSample = elapsed(at: now)
        sampleDate = now
        isPlaying.toggle()
        if isPlaying && rate == 0 { rate = 1 }
        service.send("toggle")
        timelineRevision &+= 1
    }

    func next() { service.send("next") }
    func previous() { service.send("previous") }

    func seek(to seconds: Double) {
        elapsedAtSample = min(max(seconds, 0), duration)
        sampleDate = Date()
        service.send(String(format: "seek %.3f", elapsedAtSample))
        timelineRevision &+= 1
    }

    // MARK: - Updates

    private func apply(_ u: NowPlayingService.Update) {
        let newTitle = u.title ?? ""
        let newArtist = u.artist ?? ""
        let trackChanged = newTitle != title || newArtist != artist

        title = newTitle
        artist = newArtist
        album = u.album ?? ""
        isPlaying = u.playing && !newTitle.isEmpty
        duration = u.duration ?? 0
        rate = u.rate ?? (u.playing ? 1 : 0)
        elapsedAtSample = u.elapsed ?? 0
        sampleDate = u.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()

        if let data = u.artworkData, let image = NSImage(data: data) {
            artwork = image
            accentColor = Self.averageColor(of: image) ?? .white
        } else if !u.hasArtwork {
            artwork = nil
            accentColor = .white
        }

        if u.pid != lastPID {
            lastPID = u.pid
            let app = u.pid > 0 ? NSRunningApplication(processIdentifier: u.pid) : nil
            appName = app?.localizedName
            appIcon = app?.icon
            appBundleID = app?.bundleIdentifier
        }

        if trackChanged && !newTitle.isEmpty && isPlaying {
            peek()
        }
        timelineRevision &+= 1
    }

    private func peek() {
        peekTask?.cancel()
        isPeeking = true
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.isPeeking = false }
        }
        peekTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    /// Average artwork color, lifted so it stays readable on black.
    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s, 0.7), brightness: max(b, 0.75), alpha: 1)
    }
}
