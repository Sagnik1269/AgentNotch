import AppKit

// Private CoreGraphics (SkyLight) calls used to learn which Spaces are fullscreen.
// They are stable and widely used, but are not public API, so this app can't ship on the Mac App Store.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?

enum SpaceInspector {
    private static let fullscreenSpaceType = 4

    /// Returns the display UUIDs whose current Space is a fullscreen app.
    /// `allDisplays` is true when "Displays have separate Spaces" is off and the shared Space is fullscreen.
    static func fullscreenDisplays() -> (allDisplays: Bool, uuids: Set<String>) {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else {
            return (false, [])
        }
        var uuids = Set<String>()
        var all = false
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  let type = current["type"] as? Int,
                  type == fullscreenSpaceType,
                  let id = display["Display Identifier"] as? String
            else { continue }
            if id == "Main" { all = true } else { uuids.insert(id.uppercased()) }
        }
        return (all, uuids)
    }

    static func isFullscreen(_ screen: NSScreen) -> Bool {
        let state = fullscreenDisplays()
        if state.allDisplays { return true }
        guard let uuid = screen.displayUUID else { return false }
        return state.uuids.contains(uuid)
    }
}
