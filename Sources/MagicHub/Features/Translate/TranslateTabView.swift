import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Translation

private enum TranslateLangSide { case from, to }

struct TranslateTabView: View {
    @ObservedObject private var model = TranslateModel.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var openList: TranslateLangSide?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
                .zIndex(10)
            Group {
                if model.mode == .text {
                    textBody
                } else {
                    photoBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .translationTask(model.appleConfig) { session in
            await TranslateModel.shared.runApple(session)
        }
        .panelMeta(prefs.translateEngine == .google ? "Google" : "Apple · без интернета")
    }

    // MARK: Верхняя строка

    private var topBar: some View {
        HStack(spacing: 8) {
            langButton(.from)
            Button {
                openList = nil
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(MH.card2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MH.t1)
            .help("Поменять языки местами")
            langButton(.to)
            Spacer()
            MHSegmented(options: [(TranslateModel.Mode.text, "Текст"), (TranslateModel.Mode.photo, "Фото")], selection: $model.mode)
        }
    }

    private func langButton(_ side: TranslateLangSide) -> some View {
        let lang = TranslateLanguages.byID(side == .from ? prefs.translateFrom : prefs.translateTo)
        return Button {
            openList = openList == side ? nil : side
        } label: {
            HStack(spacing: 6) {
                Text(lang.name).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
            .foregroundStyle(MH.t1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if openList == side {
                languageList(side).offset(y: 34)
            }
        }
    }

    private func languageList(_ side: TranslateLangSide) -> some View {
        let selectedID = side == .from ? prefs.translateFrom : prefs.translateTo
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(TranslateLanguages.all) { lang in
                    Button {
                        model.pick(lang.id, isFrom: side == .from)
                        openList = nil
                    } label: {
                        HStack {
                            Text(lang.name).font(.system(size: 12))
                            Spacer()
                            if lang.id == selectedID {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(lang.id == selectedID ? MH.card3 : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MH.t1)
                }
            }
            .padding(4)
        }
        .frame(width: 190, height: 210)
        .background(RoundedRectangle(cornerRadius: 10).fill(MH.card2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    // MARK: Текст

    private var textBody: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.input)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if model.input.isEmpty {
                    Text("Введите или вставьте текст")
                        .font(.system(size: 15))
                        .foregroundStyle(MH.t3)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(MH.card))

            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    Text(model.output.isEmpty ? " " : model.output)
                        .font(.system(size: 15))
                        .foregroundStyle(MH.t1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                HStack(spacing: 6) {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    MHIconButton("doc.on.doc", help: "Скопировать перевод", size: 28) {
                        guard !model.output.isEmpty else { return }
                        Clipboard.copy(model.output)
                        AppModel.shared.flash("Перевод скопирован")
                    }
                }
                .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    // MARK: Фото

    private var photoBody: some View {
        HStack(alignment: .top, spacing: 12) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            photoSidebar
                .frame(width: 190)
        }
    }

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(MH.card)
            if let img = model.image {
                TranslatePhotoCanvas(image: img, blocks: model.blocks, showTranslated: model.showTranslated)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(MH.t3)
                    Text("Перетащите картинку сюда")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MH.t1)
                    Text("или вставьте её ⌘V, или возьмите снимок с полки")
                        .font(.system(size: 11))
                        .foregroundStyle(MH.t3)
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MH.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openList = nil }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            TranslateTabView.handleDrop(providers)
        }
        .onPasteCommand(of: [UTType.fileURL, UTType.png, UTType.tiff, UTType.image]) { _ in
            _ = TranslateModel.shared.pasteFromClipboard()
        }
    }

    private var photoSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.image != nil {
                MHSegmented(options: [(false, "Оригинал"), (true, "Перевод")], selection: $model.showTranslated)
            }
            HStack(spacing: 6) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(model.photoStatus.isEmpty ? "Перевод ляжет поверх текста на картинке" : model.photoStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.image == nil {
                sideButton("Из буфера", "doc.on.clipboard") { _ = model.pasteFromClipboard() }
                sideButton("Последний снимок", "tray.full") { model.useLatestShot() }
            } else {
                HStack(spacing: 6) {
                    sideButton("Копировать", "doc.on.doc") { copyRenderedImage() }
                    sideButton("На полку", "tray.and.arrow.down") { saveRenderedImage() }
                }
                HStack(spacing: 6) {
                    sideButton("Текст", "text.alignleft") {
                        let text = model.translatedText
                        guard !text.isEmpty else { return }
                        Clipboard.copy(text)
                        AppModel.shared.flash("Текст перевода скопирован")
                    }
                    sideButton("Убрать", "xmark") { model.clearPhoto() }
                }
                sideButton("Из буфера", "doc.on.clipboard") { _ = model.pasteFromClipboard() }
            }
            Spacer(minLength: 0)
        }
    }

    private func sideButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MHButtonStyle())
    }

    private static func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                guard let url, let img = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { TranslateModel.shared.setImage(img) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let img = object as? NSImage else { return }
                DispatchQueue.main.async { TranslateModel.shared.setImage(img) }
            }
            return true
        }
        return false
    }

    // MARK: Картинка с переводом

    @MainActor
    private func renderTranslated() -> NSImage? {
        guard let img = model.image else { return nil }
        var size = model.imagePixelSize
        if size.width < 1 || size.height < 1 { size = img.size }
        let content = TranslatePhotoCanvas(image: img, blocks: model.blocks, showTranslated: true)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.nsImage
    }

    @MainActor
    private func copyRenderedImage() {
        guard let out = renderTranslated() else { return }
        Clipboard.copy(image: out)
        AppModel.shared.flash("Картинка с переводом скопирована")
    }

    @MainActor
    private func saveRenderedImage() {
        guard let out = renderTranslated(), let data = TranslateModel.pngData(out) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let url = AppPaths.dir("Shelf").appendingPathComponent("Перевод \(f.string(from: Date())).png")
        do {
            try data.write(to: url, options: .atomic)
            AppModel.shared.flash("Сохранено на полку")
        } catch {
            AppModel.shared.flash("Не удалось сохранить")
        }
    }

    // MARK: Подвал

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = model.errorText {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(MH.orange)
                Text(error).foregroundStyle(MH.orange)
            } else if prefs.translateEngine == .apple, let hint = model.appleHint {
                Image(systemName: "info.circle")
                Text(hint)
            } else if model.mode == .text {
                Text("Переводит прямо при наборе · направление меняется само")
            } else {
                Text("Текст на картинке распознаётся прямо на Mac")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(MH.t3)
        .lineLimit(1)
    }
}

// MARK: - Картинка с переводом поверх текста

struct TranslatePhotoCanvas: View {
    let image: NSImage
    let blocks: [TranslateBlock]
    let showTranslated: Bool

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                if showTranslated {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            ForEach(blocks) { block in
                                TranslateBlockView(block: block, size: geo.size)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
    }
}

private struct TranslateBlockView: View {
    let block: TranslateBlock
    let size: CGSize

    var body: some View {
        let r = CGRect(x: block.rect.minX * size.width,
                       y: block.rect.minY * size.height,
                       width: block.rect.width * size.width,
                       height: block.rect.height * size.height)
        let pad = max(1, r.height * 0.14)
        Text(block.translated)
            .font(.system(size: max(5, r.height * 0.8), weight: .medium))
            .foregroundStyle(block.fg)
            .lineLimit(1)
            .minimumScaleFactor(0.2)
            .frame(width: r.width + pad * 2, height: r.height + pad * 2)
            .background(RoundedRectangle(cornerRadius: min(4, pad)).fill(block.bg))
            .position(x: r.midX, y: r.midY)
    }
}
