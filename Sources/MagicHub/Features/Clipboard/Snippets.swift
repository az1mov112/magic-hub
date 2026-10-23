import SwiftUI
import AppKit

struct SnippetItem: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String
}

/// Заготовки — сохранённые тексты. Хранятся в snippets.json.
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var items: [SnippetItem] = []

    private let fileName = "snippets.json"
    private let io = DispatchQueue(label: "magichub.snippets.io", qos: .utility)

    var fileURL: URL { AppPaths.file(fileName) }

    init() {
        items = JSONStore.load([SnippetItem].self, from: fileName) ?? []
    }

    func upsert(_ item: SnippetItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.insert(item, at: 0)
        }
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func revealFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            JSONStore.save(items, to: fileName)
        }
        AppPaths.reveal(fileURL)
    }

    private func persist() {
        let snapshot = items
        let name = fileName
        io.async { JSONStore.save(snapshot, to: name) }
    }
}

struct SnippetsTabView: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var query = ""
    @State private var draft: SnippetItem?
    @State private var draftIsNew = false

    private var filtered: [SnippetItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.items }
        return store.items.filter { ($0.title + " " + $0.body).localizedCaseInsensitiveContains(q) }
    }

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 8) {
            if draft != nil {
                editor
            } else {
                HStack(spacing: 8) {
                    MHSearchField(text: $query, placeholder: "Поиск заготовок")
                    MHIconButton("plus", help: "Новая заготовка", size: 32) {
                        draft = SnippetItem(id: UUID(), title: "", body: "")
                        draftIsNew = true
                    }
                }
                let list = filtered
                if list.isEmpty {
                    EmptyStateView(systemImage: "pin",
                                   title: store.items.isEmpty ? "Пока пусто — добавь через +" : "Ничего не нашлось",
                                   subtitle: store.items.isEmpty ? "Сохраняйте тексты, которые часто вставляете" : "")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(list) { item in
                                SnippetCard(item: item) {
                                    draft = item
                                    draftIsNew = false
                                }
                            }
                        }
                    }
                }
                Text("Клик — скопировать, затем вставьте ⌘V")
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelMeta("\(store.items.count)")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Название", text: Binding(get: { draft?.title ?? "" }, set: { draft?.title = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(MH.card))
            TextEditor(text: Binding(get: { draft?.body ?? "" }, set: { draft?.body = $0 }))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(MH.card))
                .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if !draftIsNew, let id = draft?.id {
                    ClipConfirmButton("Удалить") {
                        store.remove(id)
                        draft = nil
                    }
                }
                Spacer()
                Button("Отмена") { draft = nil }
                    .buttonStyle(MHButtonStyle())
                Button("Сохранить") {
                    if var d = draft {
                        d.title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if d.title.isEmpty {
                            d.title = String(d.body.split(separator: "\n").first ?? "Заготовка").prefix(40).description
                        }
                        if !d.body.isEmpty || !d.title.isEmpty { store.upsert(d) }
                    }
                    draft = nil
                }
                .buttonStyle(MHButtonStyle(kind: .prominent))
            }
        }
    }
}

private struct SnippetCard: View {
    let item: SnippetItem
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.title.isEmpty ? "Без названия" : item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MH.t1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hover {
                    Button(action: onEdit) {
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(MH.t2)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Изменить")
                } else {
                    Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(MH.t3)
                }
            }
            Text(item.body)
                .font(.system(size: 12))
                .foregroundStyle(MH.t2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? MH.card2 : MH.card))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            Clipboard.copy(item.body)
            AppModel.shared.flash("Скопировано — вставьте ⌘V")
        }
    }
}
