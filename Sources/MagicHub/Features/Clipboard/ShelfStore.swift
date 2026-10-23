import AppKit
import ImageIO

/// Файл на полке.
struct ShelfItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64

    var id: String { url.path }

    var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Снимок") || name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") {
            return "Снимок " + ShelfFormat.time.string(from: date)
        }
        return name
    }
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
        if n10 == 1 && n100 != 11 { word = "снимок" }
        else if (2...4).contains(n10) && !(12...14).contains(n100) { word = "снимка" }
        else { word = "снимков" }
        return "\(n) \(word)"
    }
}

/// Полка: снимки экрана из буфера и перетащенные файлы. Лежат в Application Support/MagicHub/Shelf.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    let folder: URL = AppPaths.dir("Shelf")
    private let io = DispatchQueue(label: "magichub.shelf.io", qos: .utility)

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

    /// Скопировать файл на полку (перетаскивание, папка снимков).
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

    func remove(_ item: ShelfItem) {
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: item.url)
            self.publishScan()
        }
    }

    func clear() {
        io.async { [weak self] in
            guard let self else { return }
            for item in self.scan() { try? FileManager.default.removeItem(at: item.url) }
            self.publishScan()
        }
    }

    func applyAutoClean(_ mode: AutoClean) {
        guard mode != .off else { return }
        io.async { [weak self] in
            guard let self else { return }
            let list = self.scan()
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
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let list: [ShelfItem] = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return ShelfItem(url: u, date: v.creationDate ?? v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
        }
        return list.sorted { $0.date > $1.date }
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
