import AppKit

/// Built-in display brightness via the private DisplayServices framework.
@MainActor
final class BrightnessController {
    static let shared = BrightnessController()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetFn?
    private let setBrightness: SetFn?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setBrightness = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
    }

    /// The built-in panel, if it's on (not in clamshell mode).
    private var builtInDisplay: CGDirectDisplayID? {
        NSScreen.screens.first(where: \.isBuiltIn)?.displayID
    }

    var isAvailable: Bool { brightness != nil }

    var brightness: Float? {
        guard let display = builtInDisplay, let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }

    func setBrightness(_ value: Float) {
        guard let display = builtInDisplay, let setBrightness else { return }
        _ = setBrightness(display, min(max(value, 0), 1))
    }
}
