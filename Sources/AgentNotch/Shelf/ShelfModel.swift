import AppKit
import UniformTypeIdentifiers

/// One thing held on the shelf. Files are referenced (not copied); dropped images or text are
/// saved as files the shelf owns and deletes when removed.
struct ShelfItem: Identifiable, Equatable, Codable {
    let id: UUID
    var bookmark: Data
    var owned: Bool
    var added: Date

    /// Resolved at load and after each change.
    var url: URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    static let shared = ShelfModel()

    @Published private(set) var items: [ShelfItem] = []

    private let storeURL: URL
    private let ownedDir: URL
    private static let maxItems = 48

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
        storeURL = base.appendingPathComponent("shelf.json")
        ownedDir = base.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        load()
    }

    var urls: [URL] { items.compactMap(\.url) }

    // MARK: - Adding

    func add(urls: [URL]) {
        for url in urls where url.isFileURL {
            if items.contains(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { continue }
            guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }
            items.insert(ShelfItem(id: UUID(), bookmark: bookmark, owned: false, added: Date()), at: 0)
        }
        trimAndSave()
    }

    /// Loads whatever was dropped: file URLs, images, or text. Returns false if nothing usable.
    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.add(urls: [url]) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage,
                          let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.addOwned(data: png, ext: "png", name: "Image") } }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String, !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let isLink = URL(string: text)?.scheme?.hasPrefix("http") == true && !text.contains(" ")
                            if isLink {
                                let webloc = "[InternetShortcut]\nURL=\(text)\n"
                                self.addOwned(data: Data(webloc.utf8), ext: "url", name: URL(string: text)?.host ?? "Link")
                            } else {
                                let name = String(text.prefix(24)).components(separatedBy: .newlines).first ?? "Text"
                                self.addOwned(data: Data(text.utf8), ext: "txt", name: name)
                            }
                        }
                    }
                }
            }
        }
        return accepted
    }

    private func addOwned(data: Data, ext: String, name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var url = ownedDir.appendingPathComponent("\(safe.isEmpty ? "Item" : safe).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = ownedDir.appendingPathComponent("\(safe) \(n).\(ext)")
            n += 1
        }
        guard (try? data.write(to: url)) != nil,
              let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        items.insert(ShelfItem(id: UUID(), bookmark: bookmark, owned: true, added: Date()), at: 0)
        trimAndSave()
    }

    // MARK: - Removing

    func remove(_ item: ShelfItem) {
        if item.owned, let url = item.url { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.owned {
            if let url = item.url { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll()
        save()
    }

    // MARK: - Actions

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func copyToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    // MARK: - Persistence

    private func trimAndSave() {
        if items.count > Self.maxItems {
            for item in items[Self.maxItems...] where item.owned {
                if let url = item.url { try? FileManager.default.removeItem(at: url) }
            }
            items = Array(items.prefix(Self.maxItems))
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        // Drop items whose files are gone (deleted or on an unmounted drive).
        items = stored.filter { item in
            guard let url = item.url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        if items.count != stored.count { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

/// Detects a file drag in progress anywhere on screen, so the notch can open for it.
@MainActor
enum FileDragWatcher {
    private static var changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount

    /// Call on every mouse-down: a drag that started since then put new data on the drag pasteboard.
    static func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    }

    static var isDraggingFiles: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != changeCountAtMouseDown else { return false }
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) || types.contains(.string)
    }
}
