import AppKit
import Combine

/// Одна запись истории буфера обмена.
struct ClipItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var date: Date
}

/// История скопированного текста. Хранится в clipboard.json, без фильтров.
final class ClipHistoryStore: ObservableObject {
    static let shared = ClipHistoryStore()

    @Published private(set) var items: [ClipItem] = []

    private let fileName = "clipboard.json"
    private let io = DispatchQueue(label: "magichub.clip.io", qos: .utility)

    init() {
        items = JSONStore.load([ClipItem].self, from: fileName) ?? []
    }

    /// Добавить текст наверх; если такой уже есть — поднять его.
    func add(_ text: String) {
        guard !text.isEmpty else { return }
        if let i = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: i)
            item.date = Date()
            items.insert(item, at: 0)
        } else {
            items.insert(ClipItem(id: UUID(), text: text, date: Date()), at: 0)
        }
        persist()
    }

    func touch(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var it = items.remove(at: i)
        it.date = Date()
        items.insert(it, at: 0)
        persist()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    func applyAutoClean(_ mode: AutoClean) {
        let before = items.count
        switch mode {
        case .off:
            return
        case .days7:
            let limit = Date().addingTimeInterval(-7 * 86_400)
            items.removeAll { $0.date < limit }
        case .days30:
            let limit = Date().addingTimeInterval(-30 * 86_400)
            items.removeAll { $0.date < limit }
        case .count500:
            if items.count > 500 { items = Array(items.prefix(500)) }
        }
        if items.count != before { persist() }
    }

    private func persist() {
        let snapshot = items
        let name = fileName
        io.async { JSONStore.save(snapshot, to: name) }
    }
}

/// Следит за буфером обмена: текст → история, картинки (снимки экрана в буфер) → полка.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var timer: Timer?
    private var folderTimer: Timer?
    private var cleanTimer: Timer?
    private var lastChange: Int = NSPasteboard.general.changeCount

    /// Доступ только из `work`.
    private var knownScreenshots: Set<String> = []
    private var folderPrimed = false
    private var primedFolderPath = ""
    private let work = DispatchQueue(label: "magichub.clip.watch", qos: .utility)

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let f = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.checkScreenshotFolder() }
        RunLoop.main.add(f, forMode: .common)
        folderTimer = f

        let c = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.runAutoClean() }
        RunLoop.main.add(c, forMode: .common)
        cleanTimer = c

        ShelfStore.shared.reload()
        runAutoClean()
        checkScreenshotFolder()
    }

    /// Автоочистка истории и полки по настройке (по умолчанию выключена).
    func runAutoClean() {
        let mode = Prefs.shared.autoClean
        ClipHistoryStore.shared.applyAutoClean(mode)
        ShelfStore.shared.applyAutoClean(mode)
    }

    private func poll() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChange else { return }
        lastChange = cc
        if cc == Clipboard.ownChangeCount { return }

        if let s = pb.string(forType: .string), !s.isEmpty {
            ClipHistoryStore.shared.add(s)
            return
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            if Prefs.shared.saveClipboardImages {
                ShelfStore.shared.addImageData(data)
            }
        }
    }

    static func screenshotFolder() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            let path = AppPaths.expand(loc)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return AppPaths.home.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func checkScreenshotFolder() {
        let enabled = Prefs.shared.watchScreenshotFolder
        work.async { [weak self] in
            guard let self else { return }
            guard enabled else {
                self.knownScreenshots.removeAll()
                self.folderPrimed = false
                return
            }
            let dir = ClipboardWatcher.screenshotFolder()
            if dir.path != self.primedFolderPath {
                self.folderPrimed = false
                self.primedFolderPath = dir.path
            }
            let exts: Set<String> = ["png", "jpg", "jpeg", "heic"]
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            let images = names.filter { !$0.hasPrefix(".") && exts.contains(($0 as NSString).pathExtension.lowercased()) }
            if !self.folderPrimed {
                // Всё, что было до включения, на полку не тащим.
                self.knownScreenshots = Set(images)
                self.folderPrimed = true
                return
            }
            for name in images where !self.knownScreenshots.contains(name) {
                self.knownScreenshots.insert(name)
                ShelfStore.shared.addFile(dir.appendingPathComponent(name))
            }
        }
    }
}
