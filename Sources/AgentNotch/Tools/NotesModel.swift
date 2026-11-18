import Foundation

/// Quick notes, saved to Application Support as you type.
@MainActor
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    struct Note: Identifiable, Codable, Equatable {
        let id: UUID
        var text: String
        var updated: Date

        var title: String {
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "New note" : trimmed
        }
    }

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    private let url: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("notes.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        }
        if notes.isEmpty { notes = [Note(id: UUID(), text: "", updated: Date())] }
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func setText(_ text: String, for id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        // Most recently edited first.
        if i != 0 { notes.insert(notes.remove(at: i), at: 0) }
        scheduleSave()
    }

    func add() {
        // Reuse an empty note instead of piling them up.
        if let empty = notes.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            selectedID = empty.id
            return
        }
        let note = Note(id: UUID(), text: "", updated: Date())
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [Note(id: UUID(), text: "", updated: Date())] }
        if selectedID == id || selected == nil { selectedID = notes.first?.id }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        let kept = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
