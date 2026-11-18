import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Shelf: drop files to hold them, drag them back out anywhere, AirDrop or copy them.
struct ShelfTabView: View {
    @ObservedObject private var shelf = ShelfModel.shared
    @State private var targeted = false

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    toolbar
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $targeted) { providers in
            shelf.add(providers: providers)
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
            Text("Drop files here")
                .font(.system(size: 14, weight: .semibold))
            Text("Drag files onto the notch to hold them, then drag them out wherever you need them.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            ShelfToolbarButton(icon: "paperplane", title: "AirDrop all") { shelf.airDrop(shelf.urls) }
            ShelfToolbarButton(icon: "doc.on.doc", title: "Copy all") { shelf.copyToPasteboard(shelf.urls) }
            ShelfToolbarButton(icon: "trash", title: "Clear") { shelf.clear() }
        }
        .padding(.horizontal, 4)
    }
}

private struct ShelfToolbarButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .onHover { hovering = $0 }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject private var shelf = ShelfModel.shared
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        let url = item.url
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnail ?? url.map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "questionmark.square.dashed").font(.system(size: 26))
                    }
                }
                .frame(width: 56, height: 56)

                if hovering {
                    Button { shelf.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -4)
                    .help("Remove from shelf")
                }
            }
            Text(url?.lastPathComponent ?? "Missing file")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 26, alignment: .top)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .onDrag {
            guard let url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            if let url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("AirDrop") { shelf.airDrop([url]) }
                Button("Copy") { shelf.copyToPasteboard([url]) }
                Divider()
            }
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .help(url?.path ?? "")
        .task(id: item.id) { await loadThumbnail(url) }
    }

    private func loadThumbnail(_ url: URL?) async {
        guard let url else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        }
    }
}
