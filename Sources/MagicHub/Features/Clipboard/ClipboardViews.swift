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
    @State private var selected: Set<String> = []
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 10)]

    private var selectedItems: [ShelfItem] { store.items.filter { selected.contains($0.id) } }
    private var selectedURLs: [URL] { selectedItems.filter { !$0.missing }.map(\.url) }

    var body: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: "Полка пуста",
                               subtitle: "Перетащите файл к чёлке — он ляжет сюда, а сам останется на месте. Снимки экрана в буфер (⌃⇧⌘4) тоже попадают сюда")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.items) { item in
                            ShelfCell(item: item, isSelected: selected.contains(item.id)) {
                                tap(item)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(selected.isEmpty ? "Клик — выбрать, ⌘-клик — несколько, пробел — просмотр, перетащите куда угодно"
                                      : "Выбрано: \(selected.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    ShelfActions.airDrop(selectedURLs)
                } label: {
                    Label("AirDrop", systemImage: "dot.radiowaves.up.forward")
                }
                .buttonStyle(MHButtonStyle())
                .disabled(selectedURLs.isEmpty)
                ShareLink(items: selectedURLs) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(MHButtonStyle())
                .disabled(selectedURLs.isEmpty)
                Button(selected.count == store.items.count && !store.items.isEmpty ? "Снять выбор" : "Выбрать всё") {
                    selected = selected.count == store.items.count ? [] : Set(store.items.map(\.id))
                }
                .buttonStyle(MHButtonStyle())
                .disabled(store.items.isEmpty)
                ClipConfirmButton(selected.isEmpty ? "Очистить" : "Убрать") {
                    if selected.isEmpty { store.clear() } else { store.remove(selectedItems) }
                    selected = []
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            ShelfActions.quickLook(selectedURLs)
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: store.items) { selected = selected.intersection(Set(store.items.map(\.id))) }
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

    private func tap(_ item: ShelfItem) {
        // Панель чёлки не забирает клавиатуру сама — чтобы работал пробел, делаем её ключевой.
        NSApp.windows.first { $0 is NotchPanel && $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        focused = true
        if NSEvent.modifierFlags.contains(.command) {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } else {
            selected = selected == [item.id] ? [] : [item.id]
        }
    }
}

/// Действия с файлами полки.
enum ShelfActions {
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Быстрый просмотр (как пробел в Finder).
    static func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p"] + urls.map(\.path)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

enum ShelfDrop {
    static func handle(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { ShelfStore.shared.addReference(url) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { ShelfStore.shared.addImage(img) }
                }
            }
        }
        if handled { DispatchQueue.main.async { AppModel.shared.flash("На полке") } }
        return handled
    }
}

private struct ShelfCell: View {
    let item: ShelfItem
    let isSelected: Bool
    let onTap: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let thumb {
                        Image(nsImage: thumb).resizable()
                            .aspectRatio(contentMode: item.isReference && !isImage ? .fit : .fill)
                            .padding(item.isReference && !isImage ? 10 : 0)
                    } else {
                        Image(systemName: item.isFolder ? "folder" : "doc").font(.system(size: 18)).foregroundStyle(MH.t3)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(MH.card3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .saturation(item.missing ? 0 : 1)
            HStack(spacing: 4) {
                Text(item.title).font(.system(size: 11)).foregroundStyle(item.missing ? MH.t3 : MH.t1)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(item.sizeText).font(.system(size: 11)).foregroundStyle(item.missing ? MH.orange : MH.t3).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? MH.accent.opacity(0.22) : (hover ? MH.card2 : MH.card)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? MH.accent : Color.clear, lineWidth: 1.5))
        .opacity(item.missing ? 0.6 : 1)
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
                .help(item.isReference ? "Убрать с полки (файл останется на месте)" : "Удалить с полки")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            if !item.missing { NSWorkspace.shared.open(item.url) }
        }
        .onTapGesture(perform: onTap)
        .onDrag {
            item.missing ? NSItemProvider() : (NSItemProvider(contentsOf: item.url) ?? NSItemProvider())
        }
        .contextMenu {
            if !item.missing {
                Button("Открыть") { NSWorkspace.shared.open(item.url) }
                Button("Просмотр") { ShelfActions.quickLook([item.url]) }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Скопировать") {
                    Clipboard.copy(fileURL: item.url)
                    AppModel.shared.flash("Скопировано")
                }
                Button("AirDrop") { ShelfActions.airDrop([item.url]) }
                Divider()
            }
            Button(item.isReference ? "Убрать с полки" : "Удалить") { ShelfStore.shared.remove(item) }
        }
        .help(item.missing ? "Файл удалён или недоступен" : item.url.path.replacingOccurrences(of: AppPaths.home.path, with: "~"))
        .task(id: item.id + (item.missing ? "-missing" : "")) {
            thumb = await ShelfThumbCache.shared.load(for: item)
        }
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"].contains(item.url.pathExtension.lowercased())
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
