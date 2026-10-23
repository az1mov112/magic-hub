import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Что сделать с файлом, который бросили на чёлку.
enum DropAction: CaseIterable, Identifiable {
    case shelf, airDrop, zip, convert, copy, trash

    var id: Self { self }

    var title: String {
        switch self {
        case .shelf: return "Полка"
        case .airDrop: return "AirDrop"
        case .zip: return "ZIP"
        case .convert: return "Конвертация"
        case .copy: return "Копировать"
        case .trash: return "Удалить"
        }
    }

    var subtitle: String {
        switch self {
        case .shelf: return "Положить на полку"
        case .airDrop: return "Отправить рядом"
        case .zip: return "Сжать в архив"
        case .convert: return "Фото в JPEG"
        case .copy: return "В буфер обмена"
        case .trash: return "В корзину"
        }
    }

    var icon: String {
        switch self {
        case .shelf: return "tray.and.arrow.down"
        case .airDrop: return "dot.radiowaves.up.forward"
        case .zip: return "doc.zipper"
        case .convert: return "arrow.triangle.2.circlepath"
        case .copy: return "doc.on.doc"
        case .trash: return "trash"
        }
    }

    /// Конвертировать можно только картинки — для остальных файлов карточка серая.
    func isEnabled(for urls: [URL]) -> Bool {
        switch self {
        case .convert: return urls.isEmpty || urls.contains(where: DropActions.isImage)
        default: return true
        }
    }
}

enum DropActions {
    static let imageExts: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "tiff", "tif", "webp", "bmp", "gif"]

    static func isImage(_ url: URL) -> Bool { imageExts.contains(url.pathExtension.lowercased()) }

    /// Файлы из перетаскивания (без картинок без файла — их можно только на полку).
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    static func perform(_ action: DropAction, _ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let app = AppModel.shared
        switch action {
        case .shelf:
            urls.forEach { ShelfStore.shared.addReference($0) }
            app.flash("На полке")
        case .airDrop:
            ShelfActions.airDrop(urls)
        case .copy:
            ShelfActions.copy(urls)
            notify("Скопировано", "Вставьте файл куда угодно: ⌘V", icon: "doc.on.doc")
        case .trash:
            NSWorkspace.shared.recycle(urls) { _, error in
                notify(error == nil ? "Перемещено в корзину" : "Не удалось удалить",
                       error == nil ? (urls.count == 1 ? urls[0].lastPathComponent : "Файлов: \(urls.count)") : "Нет доступа к файлу",
                       icon: "trash", kind: error == nil ? .success : .error)
            }
        case .zip:
            DispatchQueue.global(qos: .userInitiated).async {
                let made = urls.compactMap(makeZip)
                DispatchQueue.main.async {
                    made.forEach { ShelfStore.shared.addReference($0) }
                    notify(made.isEmpty ? "Не удалось сжать" : "Архив готов",
                           made.isEmpty ? "Нет доступа к папке" : "\(made[0].lastPathComponent) — на полке и рядом с файлом",
                           icon: "doc.zipper", kind: made.isEmpty ? .error : .success)
                }
            }
        case .convert:
            let images = urls.filter(isImage)
            DispatchQueue.global(qos: .userInitiated).async {
                let made = images.compactMap(makeConverted)
                DispatchQueue.main.async {
                    made.forEach { ShelfStore.shared.addReference($0) }
                    notify(made.isEmpty ? "Не удалось конвертировать" : "Готово",
                           made.isEmpty ? "Это не похоже на картинку" : "\(made[0].lastPathComponent) — на полке и рядом с оригиналом",
                           icon: "arrow.triangle.2.circlepath", kind: made.isEmpty ? .error : .success)
                }
            }
        }
    }

    private static func notify(_ title: String, _ subtitle: String, icon: String, kind: NotchNotification.Kind = .success) {
        AppModel.shared.post(NotchNotification(title: title, subtitle: subtitle, kind: kind, icon: icon))
    }

    /// Архив рядом с файлом (или в «Загрузках», если в ту папку писать нельзя).
    private static func makeZip(_ source: URL) -> URL? {
        let base = source.lastPathComponent
        for dir in [source.deletingLastPathComponent(), FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]] {
            let dest = unique(in: dir, base: base, ext: "zip")
            let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, dest.path])
            if r.ok, FileManager.default.fileExists(atPath: dest.path) { return dest }
        }
        return nil
    }

    /// HEIC, PNG и прочее → JPEG; JPEG → PNG. Метаданные сохраняются.
    private static func makeConverted(_ source: URL) -> URL? {
        let toPNG = ["jpg", "jpeg"].contains(source.pathExtension.lowercased())
        let type = toPNG ? UTType.png : UTType.jpeg
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let base = source.deletingPathExtension().lastPathComponent
        for dir in [source.deletingLastPathComponent(), FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]] {
            let dest = unique(in: dir, base: base, ext: toPNG ? "png" : "jpg")
            guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImageFromSource(out, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(out) { return dest }
        }
        return nil
    }

    private static func unique(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }
}

/// Полоса действий, которая выезжает из чёлки, когда к ней тащат файл.
struct DropActionsView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        let g = model.geometry
        VStack(alignment: .leading, spacing: 8) {
            Text("БРОСЬТЕ НА ДЕЙСТВИЕ")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.9)
                .foregroundStyle(MH.t3)
                .frame(height: 14)
            HStack(spacing: NotchGeometry.dropGap) {
                ForEach(DropAction.allCases) { action in
                    DropCard(action: action, enabled: action.isEnabled(for: app.dragURLs))
                }
            }
        }
        .padding(.top, g.dropTopInset)
        .padding(.horizontal, NotchGeometry.dropPadding)
        .frame(width: g.dropSize.width, height: g.dropSize.height, alignment: .topLeading)
    }
}

private struct DropCard: View {
    let action: DropAction
    let enabled: Bool
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: action.icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(action == .trash ? MH.red : MH.t1)
                .frame(height: 28)
            Text(action.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MH.t1)
            Text(action.subtitle).font(.system(size: 10)).foregroundStyle(MH.t2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
        .frame(width: NotchGeometry.dropCard.width, height: NotchGeometry.dropCard.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(targeted ? 0.2 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(targeted ? 0.85 : 0.1), lineWidth: targeted ? 1.5 : 1))
        .scaleEffect(targeted ? 1.05 : 1)
        .opacity(enabled ? 1 : 0.35)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: targeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard enabled else { return false }
            DropActions.load(providers) { urls in
                DropActions.perform(action, urls)
                NotchManager.shared.endFileDrag()
            }
            return true
        }
    }
}
