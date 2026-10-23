import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Кнопка удаления с подтверждением вторым нажатием (вместо диалогов, которых в панели нет).
struct ClipConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var armed = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(armed ? "Точно?" : title) {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        }
        .buttonStyle(MHButtonStyle(kind: armed ? .destructive : .normal))
    }
}

// MARK: - Буфер

struct ClipboardTabView: View {
    @ObservedObject private var store = ClipHistoryStore.shared
    @State private var query = ""
    @AppStorage("clip.hidden") private var hidden = false

    private var filtered: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.items }
        return store.items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MHSearchField(text: $query, placeholder: "Поиск в истории")
                MHIconButton(hidden ? "eye.slash" : "eye", help: hidden ? "Показать содержимое" : "Скрыть содержимое", size: 32, active: hidden) {
                    hidden.toggle()
                }
                ClipConfirmButton("Очистить") { store.clear() }
            }
            let list = filtered
            if list.isEmpty {
                EmptyStateView(systemImage: "doc.on.clipboard",
                               title: store.items.isEmpty ? "История пуста" : "Ничего не нашлось",
                               subtitle: store.items.isEmpty ? "Всё, что вы скопируете, появится здесь" : "")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(list.prefix(500)) { item in
                            ClipRow(item: item, hidden: hidden)
                        }
                    }
                }
            }
        }
        .panelMeta("\(store.items.count)")
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let hidden: Bool
    @State private var hover = false

    private var isLink: Bool {
        let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("http://") || t.hasPrefix("https://")) && !t.contains(" ")
    }

    private var display: String {
        if hidden { return String(repeating: "•", count: min(24, max(4, item.text.count))) }
        let head = String(item.text.prefix(300))
        return head.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLink ? "link" : "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(MH.t3)
                .frame(width: 16)
            Text(display)
                .font(.system(size: 13))
                .foregroundStyle(MH.t1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                Button {
                    ClipHistoryStore.shared.remove(item)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(MH.t2)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Удалить из истории")
            } else {
                Text(Fmt.ago(item.date)).font(.system(size: 11)).foregroundStyle(MH.t3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover ? MH.card2 : MH.card))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            Clipboard.copy(item.text)
            ClipHistoryStore.shared.touch(item)
            AppModel.shared.flash("Скопировано")
        }
    }
}

// MARK: - Полка

struct ShelfTabView: View {
    @ObservedObject private var store = ShelfStore.shared
    @State private var dropTarget = false

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 10)]

    var body: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: "Полка пуста",
                               subtitle: "Сделайте снимок экрана в буфер (⌃⇧⌘4) или перетащите сюда файл")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.items) { item in
                            ShelfCell(item: item)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Перетащите снимок в любое приложение · клик — снова в буфер")
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Показать в Finder") { NSWorkspace.shared.open(store.folder) }
                    .buttonStyle(MHButtonStyle())
                ClipConfirmButton("Очистить") { store.clear() }
            }
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MH.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTarget) { providers in
            ShelfDrop.handle(providers)
        }
        .panelMeta(ShelfFormat.countText(store.items.count) + " · " + Fmt.bytes(Double(store.totalSize)))
    }
}

enum ShelfDrop {
    static func handle(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { ShelfStore.shared.addFile(url) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { ShelfStore.shared.addImage(img) }
                }
            }
        }
        return handled
    }
}

private struct ShelfCell: View {
    let item: ShelfItem
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(MH.t3)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(MH.card3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Text(item.title).font(.system(size: 11)).foregroundStyle(MH.t1).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.bytes(Double(item.size))).font(.system(size: 11)).foregroundStyle(MH.t3).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? MH.card2 : MH.card))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button {
                    ShelfStore.shared.remove(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.75)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Удалить с полки")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            Clipboard.copy(fileURL: item.url)
            AppModel.shared.flash("Скопировано")
        }
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .task(id: item.url) {
            let url = item.url
            let image: NSImage? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: ShelfThumbCache.shared.thumbnail(for: url))
                }
            }
            thumb = image
        }
    }
}

// MARK: - Настройки

struct ClipboardSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var history = ClipHistoryStore.shared

    var body: some View {
        SettingsSection("Буфер и полка") {
            SettingsToggleRow("Сохранять скриншоты из буфера",
                              subtitle: "Каждый снимок в буфер (⌃⇧⌘4) попадает на полку",
                              isOn: $prefs.saveClipboardImages)
            SettingsToggleRow("Следить за папкой снимков",
                              subtitle: ClipboardWatcher.screenshotFolder().path.replacingOccurrences(of: AppPaths.home.path, with: "~"),
                              isOn: $prefs.watchScreenshotFolder)
            SettingsSegmentRow("Автоочистка",
                               subtitle: "Сохраняется всё, что вы скопировали, без фильтров",
                               options: [(AutoClean.off, "Выкл."), (AutoClean.days7, "7 дней"), (AutoClean.days30, "30 дней"), (AutoClean.count500, "> 500 шт.")],
                               selection: $prefs.autoClean)
            SettingsButtonRow("Папка снимков", buttonTitle: "Показать в Finder") {
                NSWorkspace.shared.open(shelf.folder)
            }
            SettingsRow("Полка занимает \(Fmt.bytes(Double(shelf.totalSize)))", subtitle: ShelfFormat.countText(shelf.items.count)) {
                ClipConfirmButton("Очистить полку") { shelf.clear() }
            }
            SettingsRow("История буфера", subtitle: "Записей: \(history.items.count)") {
                ClipConfirmButton("Очистить историю") { history.clear() }
            }
            SettingsButtonRow("Заготовки", buttonTitle: "Показать файл") {
                SnippetStore.shared.revealFile()
            }
        }
        .onChange(of: prefs.autoClean) {
            ClipboardWatcher.shared.runAutoClean()
        }
    }
}
