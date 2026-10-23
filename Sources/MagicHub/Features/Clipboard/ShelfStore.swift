import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Файл на полке: снимок экрана, сохранённый в папку полки, или ссылка на файл,
/// который перетащили к чёлке (сам файл остаётся на месте).
struct ShelfItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    var isReference = false
    var missing = false
    var isFolder = false

    var id: String { url.path }

    var title: String {
        if isReference { return url.lastPathComponent }
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Снимок") || name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") {
            return "Снимок " + ShelfFormat.time.string(from: date)
        }
        return name
    }

    var sizeText: String {
        if missing { return "не найден" }
        if isFolder { return "папка" }
        return Fmt.bytes(Double(size))
    }
}

/// Ссылка на файл на полке. Закладка (bookmark) находит файл, даже если его переименовали или перенесли.
private struct ShelfRef: Codable {
    var bookmark: Data
    var path: String
    var added: Date
}

enum ShelfFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "HH:mm"
        return f
    }()

    static func fileBaseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Снимок " + f.string(from: date)
    }

    static func countText(_ n: Int) -> String {
        let n10 = n % 10, n100 = n % 100
        let word: String
        if n10 == 1 && n100 != 11 { word = "файл" }
        else if (2...4).contains(n10) && !(12...14).contains(n100) { word = "файла" }
        else { word = "файлов" }
        return "\(n) \(word)"
    }
}

/// Полка: снимки экрана из буфера и перетащенные файлы. Лежат в Application Support/MagicHub/Shelf.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    let folder: URL = AppPaths.dir("Shelf")
    private let io = DispatchQueue(label: "magichub.shelf.io", qos: .utility)
    /// Ссылки на перетащенные файлы (только на очереди io).
    private var refs: [ShelfRef] = []
    private var refsLoaded = false
    private static let refsFile = "shelf-refs.json"

    init() {
        reload()
    }

    /// Самый свежий снимок на полке (для перевода фото).
    var latestImageURL: URL? {
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
        return items.first(where: { exts.contains($0.url.pathExtension.lowercased()) })?.url
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func reload() {
        io.async { [weak self] in
            guard let self else { return }
            let list = self.scan()
            DispatchQueue.main.async { self.items = list }
        }
    }

    /// Картинка из буфера обмена (png или tiff) → PNG-файл на полке.
    func addImageData(_ data: Data) {
        io.async { [weak self] in
            guard let self else { return }
            let png: Data?
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                png = data
            } else {
                png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            }
            guard let png else { return }
            let url = self.uniqueURL(base: ShelfFormat.fileBaseName(for: Date()), ext: "png")
            try? png.write(to: url, options: .atomic)
            self.publishScan()
        }
    }

    func addImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation else { return }
        addImageData(tiff)
    }

    /// Положить на полку ссылку на файл или папку — без копирования.
    func addReference(_ url: URL) {
        io.async { [weak self] in
            guard let self else { return }
            self.loadRefsIfNeeded()
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { return }
            if url.deletingLastPathComponent().standardizedFileURL.path == self.folder.standardizedFileURL.path { return }
            self.refs.removeAll { $0.path == path }
            guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
            self.refs.append(ShelfRef(bookmark: bookmark, path: path, added: Date()))
            self.saveRefs()
            self.publishScan()
        }
    }

    /// Скопировать файл на полку (папка снимков экрана).
    func addFile(_ source: URL) {
        io.async { [weak self] in
            guard let self else { return }
            if source.deletingLastPathComponent().standardizedFileURL.path == self.folder.standardizedFileURL.path { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else { return }
            let base = source.deletingPathExtension().lastPathComponent
            let dest = self.uniqueURL(base: base, ext: source.pathExtension)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                return
            }
            self.publishScan()
        }
    }

    /// Убрать с полки. Ссылка просто забывается (файл остаётся на месте), снимок удаляется.
    func remove(_ items: [ShelfItem]) {
        io.async { [weak self] in
            guard let self else { return }
            self.loadRefsIfNeeded()
            var refsChanged = false
            for item in items {
                if item.isReference {
                    self.refs.removeAll { $0.path == item.url.path }
                    refsChanged = true
                } else {
                    try? FileManager.default.removeItem(at: item.url)
                }
            }
            if refsChanged { self.saveRefs() }
            self.publishScan()
        }
    }

    func remove(_ item: ShelfItem) { remove([item]) }

    func clear() {
        io.async { [weak self] in
            guard let self else { return }
            for item in self.scanStored() { try? FileManager.default.removeItem(at: item.url) }
            self.refs = []
            self.refsLoaded = true
            self.saveRefs()
            self.publishScan()
        }
    }

    func applyAutoClean(_ mode: AutoClean) {
        guard mode != .off else { return }
        io.async { [weak self] in
            guard let self else { return }
            let list = self.scanStored()
            var toDelete: [ShelfItem] = []
            switch mode {
            case .off:
                break
            case .days7:
                let limit = Date().addingTimeInterval(-7 * 86_400)
                toDelete = list.filter { $0.date < limit }
            case .days30:
                let limit = Date().addingTimeInterval(-30 * 86_400)
                toDelete = list.filter { $0.date < limit }
            case .count500:
                if list.count > 500 { toDelete = Array(list.dropFirst(500)) }
            }
            guard !toDelete.isEmpty else { return }
            for item in toDelete { try? FileManager.default.removeItem(at: item.url) }
            self.publishScan()
        }
    }

    // MARK: - Внутреннее (только на очереди io)

    private func publishScan() {
        let list = scan()
        DispatchQueue.main.async { self.items = list }
    }

    private func scan() -> [ShelfItem] {
        loadRefsIfNeeded()
        return (scanStored() + resolveRefs()).sorted { $0.date > $1.date }
    }

    /// Снимки, сохранённые в папку полки.
    private func scanStored() -> [ShelfItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return ShelfItem(url: u, date: v.creationDate ?? v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
        }
    }

    /// Ссылки → файлы. Переименованный или перенесённый файл находится по закладке; удалённый — серый.
    private func resolveRefs() -> [ShelfItem] {
        var changed = false
        let items: [ShelfItem] = refs.indices.map { i in
            var stale = false
            let ref = refs[i]
            if let url = try? URL(resolvingBookmarkData: ref.bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                if stale || url.path != ref.path,
                   let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    refs[i].bookmark = fresh
                    refs[i].path = url.path
                    changed = true
                }
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                return ShelfItem(url: url, date: ref.added, size: Int64(v?.fileSize ?? 0), isReference: true,
                                 isFolder: v?.isDirectory ?? false)
            }
            return ShelfItem(url: URL(fileURLWithPath: ref.path), date: ref.added, size: 0, isReference: true, missing: true)
        }
        if changed { saveRefs() }
        return items
    }

    private func loadRefsIfNeeded() {
        guard !refsLoaded else { return }
        refsLoaded = true
        refs = JSONStore.load([ShelfRef].self, from: Self.refsFile) ?? []
    }

    private func saveRefs() {
        JSONStore.save(refs, to: Self.refsFile)
    }

    private func uniqueURL(base: String, ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var url = folder.appendingPathComponent(base + suffix)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(i))" + suffix)
            i += 1
        }
        return url
    }
}

/// Кэш миниатюр полки.
final class ShelfThumbCache {
    static let shared = ShelfThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, maxPixel: Int = 360) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var result: NSImage?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        if result == nil {
            result = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let result { cache.setObject(result, forKey: key) }
        return result
    }
}

extension ShelfThumbCache {
    /// Миниатюра любого файла: картинки — через ImageIO, остальное — через Quick Look (как в Finder).
    func load(for item: ShelfItem, size: CGFloat = 180) async -> NSImage? {
        if item.missing { return NSWorkspace.shared.icon(for: .data) }
        let url = item.url
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
        if exts.contains(url.pathExtension.lowercased()) {
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async { cont.resume(returning: self.thumbnail(for: url)) }
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
