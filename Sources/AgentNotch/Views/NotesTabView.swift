import SwiftUI

/// Notes: a short list on the left, the editor on the right. Saves as you type.
struct NotesTabView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var notes = NotesModel.shared
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                HStack {
                    Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button {
                        notes.add()
                        editorFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .help("New note")
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(notes.notes) { note in
                            NoteListRow(note: note, isSelected: note.id == notes.selectedID) {
                                notes.selectedID = note.id
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: 140)
            .frame(maxHeight: .infinity)
            .card()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
        .onChange(of: editorFocused) { _, focused in vm.isEditing = focused }
        .onDisappear { vm.isEditing = false }
    }

    @ViewBuilder private var editor: some View {
        if let id = notes.selectedID {
            TextEditor(text: Binding(
                get: { notes.selected?.text ?? "" },
                set: { notes.setText($0, for: id) }
            ))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($editorFocused)
            .padding(8)
            .overlay(alignment: .topLeading) {
                if (notes.selected?.text ?? "").isEmpty {
                    Text("Write something…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct NoteListRow: View {
    let note: NotesModel.Note
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(note.updated, format: .relative(presentation: .named))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(isSelected ? 0.14 : (hovering ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Button("Delete", role: .destructive) { NotesModel.shared.delete(note.id) }
        }
    }
}
