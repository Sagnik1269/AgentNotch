import AppKit

extension NSScreen {
    /// CoreGraphics display ID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable UUID string, matching the "Display Identifier" used by the window server's space list.
    var displayUUID: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }

    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// True when the screen has a camera housing cut into the top edge.
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Size of the physical notch, or a sensible "virtual notch" size for screens without one.
    var notchSize: CGSize {
        if hasPhysicalNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
        }
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        return CGSize(width: 190, height: menuBarHeight > 0 ? menuBarHeight : 24)
    }
}
