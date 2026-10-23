import SwiftUI

struct NoteItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var updated: Date

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Без названия" : t
    }

    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : ""
    }
}

/// Заметки. Хранятся в notes.json, сохраняются автоматически с небольшой задержкой.
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [NoteItem] = []
    @Published var selectedID: UUID?

    private let fileName = "notes.json"
    private let io = DispatchQueue(label: "magichub.notes.io", qos: .utility)
    private var saveWork: DispatchWorkItem?

    init() {
        notes = JSONStore.load([NoteItem].self, from: fileName) ?? []
        selectedID = notes.first?.id
    }

    var selected: NoteItem? { notes.first(where: { $0.id == selectedID }) }

    func add() {
        let note = NoteItem(id: UUID(), text: "", updated: Date())
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave(immediate: true)
    }

    func text(for id: UUID) -> String { notes.first(where: { $0.id == id })?.text ?? "" }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        scheduleSave(immediate: false)
    }

    func remove(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: i)
        if selectedID == id {
            selectedID = notes.isEmpty ? nil : notes[min(i, notes.count - 1)].id
        }
        scheduleSave(immediate: true)
    }

    private func scheduleSave(immediate: Bool) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.notes
            let name = self.fileName
            self.io.async { JSONStore.save(snapshot, to: name) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.6), execute: work)
    }
}

struct NotesTabView: View {
    @ObservedObject private var store = NoteStore.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Button {
                    store.add()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Новая заметка").font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(MH.card3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(MH.t1)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.notes) { note in
                            NoteRow(note: note, selected: note.id == store.selectedID) {
                                store.selectedID = note.id
                            }
                        }
                    }
                }
            }
            .frame(width: 200)

            if let id = store.selectedID, store.notes.contains(where: { $0.id == id }) {
                TextEditor(text: Binding(get: { store.text(for: id) }, set: { store.update(id, text: $0) }))
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MH.card))
                    .id(id)
            } else {
                EmptyStateView(systemImage: "note.text", title: "Нет заметок", subtitle: "Нажмите «Новая заметка»")
            }
        }
        .panelMeta("\(store.notes.count)")
    }
}

private struct NoteRow: View {
    let note: NoteItem
    let selected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(MH.t1).lineLimit(1)
                Text(note.preview.isEmpty ? Fmt.ago(note.updated) : note.preview)
                    .font(.system(size: 11)).foregroundStyle(MH.t3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                ClipConfirmButton("Удалить") { NoteStore.shared.remove(note.id) }
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? MH.card3 : (hover ? MH.card2 : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
    }
}
