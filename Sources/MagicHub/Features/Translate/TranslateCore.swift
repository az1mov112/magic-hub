import AppKit
import SwiftUI
import Combine
import Vision
import Translation

// MARK: - Языки

struct TranslateLanguage: Identifiable, Equatable {
    let id: String
    let name: String
    /// Код для Google.
    let google: String
    /// Код для переводчика Apple; пусто — Apple этот язык не переводит.
    let apple: String
    /// Код для распознавания текста (Vision); пусто — не распознаётся.
    let vision: String
}

enum TranslateLanguages {
    static let all: [TranslateLanguage] = [
        TranslateLanguage(id: "ru", name: "Русский", google: "ru", apple: "ru", vision: "ru-RU"),
        TranslateLanguage(id: "en", name: "Английский", google: "en", apple: "en", vision: "en-US"),
        TranslateLanguage(id: "kk", name: "Казахский", google: "kk", apple: "", vision: ""),
        TranslateLanguage(id: "de", name: "Немецкий", google: "de", apple: "de", vision: "de-DE"),
        TranslateLanguage(id: "fr", name: "Французский", google: "fr", apple: "fr", vision: "fr-FR"),
        TranslateLanguage(id: "es", name: "Испанский", google: "es", apple: "es", vision: "es-ES"),
        TranslateLanguage(id: "it", name: "Итальянский", google: "it", apple: "it", vision: "it-IT"),
        TranslateLanguage(id: "tr", name: "Турецкий", google: "tr", apple: "tr", vision: "tr-TR"),
        TranslateLanguage(id: "uk", name: "Украинский", google: "uk", apple: "uk", vision: "uk-UA"),
        TranslateLanguage(id: "zh", name: "Китайский", google: "zh-CN", apple: "zh-Hans", vision: "zh-Hans"),
        TranslateLanguage(id: "ja", name: "Японский", google: "ja", apple: "ja", vision: "ja-JP"),
        TranslateLanguage(id: "ko", name: "Корейский", google: "ko", apple: "ko", vision: "ko-KR"),
        TranslateLanguage(id: "ar", name: "Арабский", google: "ar", apple: "ar", vision: "ar-SA"),
        TranslateLanguage(id: "pt", name: "Португальский", google: "pt", apple: "pt", vision: "pt-BR"),
        TranslateLanguage(id: "pl", name: "Польский", google: "pl", apple: "pl", vision: "pl-PL")
    ]

    static func byID(_ id: String) -> TranslateLanguage {
        all.first(where: { $0.id == id }) ?? all[1]
    }

    /// Языки на кириллице и на латинице — для автоматической смены направления.
    static let cyrillic: Set<String> = ["ru", "uk", "kk"]
    static let latin: Set<String> = ["en", "de", "fr", "es", "it", "tr", "pt", "pl"]
}

// MARK: - Google

enum TranslateGoogle {
    enum Failure: LocalizedError {
        case badResponse
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "непонятный ответ сервера"
            case .http(429): return "Google временно ограничил переводы — подождите минуту или включите переводчик Apple в настройках"
            case .http(let code): return "сервер ответил \(code)"
            }
        }
    }

    static func isRateLimit(_ error: Error) -> Bool {
        if case Failure.http(let code) = error { return code == 429 }
        return false
    }

    /// Бесплатные адреса Google: у каждого свой лимит. Ответил 429 — минуту его не трогаем и пробуем следующий.
    private enum Endpoint: CaseIterable {
        case googleapis, google, clients5

        func url(_ text: String, from: String, to: String) -> URL? {
            let q = "sl=\(TranslateGoogle.encode(from))&tl=\(TranslateGoogle.encode(to))&q=\(TranslateGoogle.encode(text))"
            switch self {
            case .googleapis: return URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&" + q)
            case .google: return URL(string: "https://translate.google.com/translate_a/single?client=gtx&dt=t&" + q)
            case .clients5: return URL(string: "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&" + q)
            }
        }
    }

    /// Кэш переводов и «остывающие» адреса. Доступ из разных задач — под замком.
    private final class State {
        private let lock = NSLock()
        private var cooldown: [Endpoint: Date] = [:]
        private var cache: [String: String] = [:]
        private var order: [String] = []

        func cached(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return cache[key]
        }

        func store(_ key: String, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            if cache[key] == nil { order.append(key) }
            cache[key] = value
            if order.count > 300 { cache[order.removeFirst()] = nil }
        }

        func available(_ e: Endpoint) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return (cooldown[e] ?? .distantPast) < Date()
        }

        func coolDown(_ e: Endpoint) {
            lock.lock(); defer { lock.unlock() }
            cooldown[e] = Date().addingTimeInterval(60)
        }
    }

    private static let state = State()

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let chunkLimit = 1400

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Перевод произвольного текста (длинный — кусками по строкам).
    static func translate(_ text: String, from: String, to: String) async throws -> String {
        var parts: [String] = []
        for chunk in chunks(text) {
            parts.append(try await translateChunk(chunk, from: from, to: to))
        }
        return parts.joined(separator: "\n")
    }

    /// Перевод строк пачками: склеиваем через \n, делим обратно; если не совпало — построчно.
    static func translateLines(_ lines: [String], from: String, to: String) async throws -> [String] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var length = 0
        for (i, line) in lines.enumerated() {
            if !current.isEmpty && length + line.count + 1 > chunkLimit {
                groups.append(current)
                current = []
                length = 0
            }
            current.append(i)
            length += line.count + 1
        }
        if !current.isEmpty { groups.append(current) }

        var result = lines
        for group in groups {
            let source = group.map { lines[$0] }
            let joined = source.joined(separator: "\n")
            let translated = try await translateChunk(joined, from: from, to: to)
            let pieces = translated.components(separatedBy: "\n")
            if pieces.count == source.count {
                for (k, idx) in group.enumerated() {
                    result[idx] = pieces[k].trimmingCharacters(in: .whitespaces)
                }
            } else {
                for idx in group {
                    result[idx] = try await translateChunk(lines[idx], from: from, to: to)
                }
            }
        }
        return result
    }

    static func translateChunk(_ text: String, from: String, to: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }
        let key = from + "|" + to + "|" + text
        if let hit = state.cached(key) { return hit }
        var lastError: Error = Failure.http(429)   // все адреса «остывают»
        for endpoint in Endpoint.allCases where state.available(endpoint) {
            do {
                let result = try await request(endpoint, text: text, from: from, to: to)
                state.store(key, result)
                return result
            } catch Failure.http(let code) where code == 429 || code >= 500 {
                state.coolDown(endpoint)
                lastError = Failure.http(code)
            }
        }
        throw lastError
    }

    private static func request(_ endpoint: Endpoint, text: String, from: String, to: String) async throws -> String {
        guard let url = endpoint.url(text, from: from, to: to) else { throw Failure.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.http(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw Failure.badResponse }
        // translate_a/t: ["перевод"] или [["перевод","en"]]; translate_a/single: [[["кусок","оригинал",…],…],…]
        if let s = root.first as? String { return s }
        guard let first = root.first as? [Any] else { throw Failure.badResponse }
        if let s = first.first as? String { return s }
        var out = ""
        for item in first {
            if let arr = item as? [Any], let piece = arr.first as? String { out += piece }
        }
        guard !out.isEmpty else { throw Failure.badResponse }
        return out
    }

    private static func chunks(_ text: String) -> [String] {
        if text.count <= chunkLimit { return [text] }
        var result: [String] = []
        var current = ""
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            while line.count > chunkLimit {
                if !current.isEmpty { result.append(current); current = "" }
                let idx = line.index(line.startIndex, offsetBy: chunkLimit)
                result.append(String(line[..<idx]))
                line = String(line[idx...])
            }
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= chunkLimit {
                current += "\n" + line
            } else {
                result.append(current)
                current = line
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Распознавание текста на картинке

struct TranslateOCRLine {
    let text: String
    /// Нормированные координаты, начало — в левом верхнем углу.
    let rect: CGRect
}

enum TranslateOCR {
    static func recognize(_ image: CGImage, hints: [String]) throws -> [TranslateOCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            var langs: [String] = []
            for h in hints where !h.isEmpty && supported.contains(h) && !langs.contains(h) { langs.append(h) }
            if !langs.isEmpty { request.recognitionLanguages = langs }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var lines: [TranslateOCRLine] = []
        for o in observations {
            guard let candidate = o.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let b = o.boundingBox
            lines.append(TranslateOCRLine(text: text, rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
        }
        return lines
    }
}

// MARK: - Цвета фона и текста под строкой

struct TranslateRGB {
    var r: Double
    var g: Double
    var b: Double

    static let white = TranslateRGB(r: 1, g: 1, b: 1)
    static let black = TranslateRGB(r: 0, g: 0, b: 0)

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    func distance(_ o: TranslateRGB) -> Double { abs(r - o.r) + abs(g - o.g) + abs(b - o.b) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

final class TranslatePixels {
    let width: Int
    let height: Int
    private var data: [UInt8]

    init?(_ image: CGImage, maxSide: Int = 1400) {
        let longest = max(image.width, image.height)
        let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        width = w
        height = h
        data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }

    /// Пиксель (x, y), y отсчитывается сверху.
    func at(_ x: Int, _ y: Int) -> TranslateRGB {
        let cx = min(max(0, x), width - 1)
        let cy = min(max(0, y), height - 1)
        let i = (cy * width + cx) * 4
        return TranslateRGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255)
    }

    /// Фон — медиана по рамке вокруг строки; текст — самые «непохожие» на фон пиксели внутри.
    func colors(for rect: CGRect) -> (bg: TranslateRGB, fg: TranslateRGB) {
        let x0 = Int(rect.minX * Double(width))
        let x1 = Int(rect.maxX * Double(width))
        let y0 = Int(rect.minY * Double(height))
        let y1 = Int(rect.maxY * Double(height))
        let pad = max(1, Int(Double(max(1, y1 - y0)) * 0.15))
        let stepX = max(1, (x1 - x0) / 40)
        let stepY = max(1, (y1 - y0) / 8)

        var border: [TranslateRGB] = []
        for x in stride(from: x0 - pad, through: x1 + pad, by: stepX) {
            border.append(at(x, y0 - pad))
            border.append(at(x, y1 + pad))
        }
        for y in stride(from: y0 - pad, through: y1 + pad, by: stepY) {
            border.append(at(x0 - pad, y))
            border.append(at(x1 + pad, y))
        }
        let bg = TranslatePixels.median(border)

        var inside: [TranslateRGB] = []
        let ix = max(1, (x1 - x0) / 36)
        let iy = max(1, (y1 - y0) / 10)
        for y in stride(from: y0, through: y1, by: iy) {
            for x in stride(from: x0, through: x1, by: ix) { inside.append(at(x, y)) }
        }
        var fg = bg.luminance > 0.55 ? TranslateRGB.black : TranslateRGB.white
        if !inside.isEmpty {
            let sorted = inside.sorted { $0.distance(bg) > $1.distance(bg) }
            let top = Array(sorted.prefix(max(1, sorted.count / 7)))
            let avg = TranslatePixels.average(top)
            if avg.distance(bg) > 0.45 { fg = avg }
        }
        return (bg, fg)
    }

    private static func median(_ colors: [TranslateRGB]) -> TranslateRGB {
        guard !colors.isEmpty else { return .white }
        func med(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }
        return TranslateRGB(r: med(colors.map { $0.r }), g: med(colors.map { $0.g }), b: med(colors.map { $0.b }))
    }

    private static func average(_ colors: [TranslateRGB]) -> TranslateRGB {
        guard !colors.isEmpty else { return .black }
        let n = Double(colors.count)
        return TranslateRGB(r: colors.reduce(0) { $0 + $1.r } / n,
                            g: colors.reduce(0) { $0 + $1.g } / n,
                            b: colors.reduce(0) { $0 + $1.b } / n)
    }
}

struct TranslateBlock: Identifiable {
    let id = UUID()
    let rect: CGRect
    let original: String
    var translated: String
    let bg: Color
    let fg: Color
}

// MARK: - Состояние вкладки «Перевод»

final class TranslateModel: ObservableObject {
    static let shared = TranslateModel()

    enum Mode: Hashable { case text, photo }
    enum AppleJob {
        case text(String)
        case lines([String])
    }

    @Published var mode: Mode = .text
    @Published var input: String = "" {
        didSet { if input != oldValue { scheduleTranslate() } }
    }
    @Published var output: String = ""
    @Published var isWorking = false
    @Published var errorText: String?
    @Published var appleHint: String?
    @Published var appleConfig: TranslationSession.Configuration?

    @Published var image: NSImage?
    @Published var imagePixelSize: CGSize = .zero
    @Published var blocks: [TranslateBlock] = []
    @Published var showTranslated = true
    @Published var photoStatus = ""

    private var pendingApple: AppleJob?
    private var work: DispatchWorkItem?
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let p = Prefs.shared
        p.$translateFrom.map { _ in () }
            .merge(with: p.$translateTo.map { _ in () }, p.$translateEngine.map { _ in () })
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] in self?.languagesChanged() }
            .store(in: &cancellables)
    }

    var fromLanguage: TranslateLanguage { TranslateLanguages.byID(Prefs.shared.translateFrom) }
    var toLanguage: TranslateLanguage { TranslateLanguages.byID(Prefs.shared.translateTo) }

    // MARK: Языки

    func pick(_ id: String, isFrom: Bool) {
        let p = Prefs.shared
        if isFrom {
            if id == p.translateTo { p.translateTo = p.translateFrom }
            p.translateFrom = id
        } else {
            if id == p.translateFrom { p.translateFrom = p.translateTo }
            p.translateTo = id
        }
    }

    func swapLanguages() {
        let p = Prefs.shared
        let from = p.translateFrom
        p.translateFrom = p.translateTo
        p.translateTo = from
        if mode == .text && !output.isEmpty && !isWorking {
            let o = output
            output = input
            input = o
        }
    }

    private func languagesChanged() {
        if mode == .text {
            if !input.isEmpty { translateNow() }
        } else if !blocks.isEmpty {
            generation += 1
            translateBlocks(gen: generation)
        }
    }

    /// Как в Cyclop: начали печатать по-русски при «X → Русский» — направление меняется само.
    private func autoDirection(for text: String) {
        let hasCyr = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let hasLatin = text.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        let p = Prefs.shared
        let cyr = TranslateLanguages.cyrillic
        let lat = TranslateLanguages.latin
        if hasCyr && !hasLatin && !cyr.contains(p.translateFrom) && cyr.contains(p.translateTo) {
            let f = p.translateFrom
            p.translateFrom = p.translateTo
            p.translateTo = f
        } else if hasLatin && !hasCyr && cyr.contains(p.translateFrom) && lat.contains(p.translateTo) {
            let f = p.translateFrom
            p.translateFrom = p.translateTo
            p.translateTo = f
        }
    }

    // MARK: Текст

    private func scheduleTranslate() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoDirection(for: self.input)
            self.translateNow()
        }
        work = w
        // Живой перевод — не на каждую букву: Google ограничивает частые запросы.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    func translateNow() {
        let text = input
        generation += 1
        let gen = generation
        errorText = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output = ""
            isWorking = false
            return
        }
        let from = fromLanguage
        let to = toLanguage
        if Prefs.shared.translateEngine == .apple {
            startApple(.text(text), from: from, to: to)
            return
        }
        isWorking = true
        Task {
            do {
                let result = try await TranslateGoogle.translate(text, from: from.google, to: to.google)
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.output = result
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.isWorking = false
                    // Google ограничил запросы — перевести на самом Mac переводчиком Apple.
                    if TranslateGoogle.isRateLimit(error), !from.apple.isEmpty, !to.apple.isEmpty {
                        self.startApple(.text(text), from: from, to: to)
                        return
                    }
                    self.errorText = "Не удалось перевести: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Переводчик Apple

    private func startApple(_ job: AppleJob, from: TranslateLanguage, to: TranslateLanguage) {
        guard !from.apple.isEmpty, !to.apple.isEmpty else {
            let name = from.apple.isEmpty ? from.name : to.name
            appleHint = "Переводчик Apple не знает язык «\(name)» — выберите Google в настройках"
            isWorking = false
            if case .lines = job { photoStatus = "Apple не переводит этот язык" }
            return
        }
        pendingApple = job
        isWorking = true
        let src = Locale.Language(identifier: from.apple)
        let dst = Locale.Language(identifier: to.apple)
        if let c = appleConfig, c.source == src, c.target == dst {
            appleConfig?.invalidate()
        } else {
            appleConfig = TranslationSession.Configuration(source: src, target: dst)
        }
        checkAppleAvailability(src, dst)
    }

    private func checkAppleAvailability(_ src: Locale.Language, _ dst: Locale.Language) {
        Task {
            let status = await LanguageAvailability().status(from: src, to: dst)
            await MainActor.run {
                switch status {
                case .installed:
                    self.appleHint = nil
                case .supported:
                    self.appleHint = "Языки ещё не скачаны: Системные настройки → Основные → Язык и регион → Языки перевода"
                case .unsupported:
                    self.appleHint = "Apple не переводит эту пару языков — выберите Google в настройках"
                @unknown default:
                    self.appleHint = nil
                }
            }
        }
    }

    /// Вызывается из `.translationTask` во вкладке.
    func runApple(_ session: TranslationSession) async {
        let job: AppleJob? = await MainActor.run { () -> AppleJob? in
            let j = self.pendingApple
            self.pendingApple = nil
            return j
        }
        guard let job else { return }
        do {
            switch job {
            case .text(let text):
                let response = try await session.translate(text)
                let result = response.targetText
                await MainActor.run {
                    self.output = result
                    self.isWorking = false
                    self.appleHint = nil
                }
            case .lines(let lines):
                var requests: [TranslationSession.Request] = []
                for (i, line) in lines.enumerated() {
                    requests.append(TranslationSession.Request(sourceText: line, clientIdentifier: String(i)))
                }
                let responses = try await session.translations(from: requests)
                var result = lines
                for r in responses {
                    if let id = r.clientIdentifier, let i = Int(id), i < result.count { result[i] = r.targetText }
                }
                let final = result
                await MainActor.run { self.applyTranslatedLines(final) }
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run {
                self.isWorking = false
                self.errorText = "Переводчик Apple: \(message)"
                if self.mode == .photo { self.photoStatus = "Не удалось перевести" }
            }
        }
    }

    // MARK: Фото

    func setImage(_ img: NSImage) {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            photoStatus = "Не удалось прочитать картинку"
            return
        }
        mode = .photo
        image = img
        imagePixelSize = CGSize(width: cg.width, height: cg.height)
        blocks = []
        showTranslated = true
        processPhoto(cg)
    }

    func clearPhoto() {
        generation += 1
        image = nil
        blocks = []
        photoStatus = ""
        isWorking = false
    }

    @discardableResult
    func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let img = NSImage(contentsOf: url) {
            setImage(img)
            return true
        }
        if let img = NSImage(pasteboard: pb) {
            setImage(img)
            return true
        }
        AppModel.shared.flash("В буфере нет картинки")
        return false
    }

    func useLatestShot() {
        guard let url = ShelfStore.shared.latestImageURL, let img = NSImage(contentsOf: url) else {
            AppModel.shared.flash("На полке нет снимков")
            return
        }
        setImage(img)
    }

    private func processPhoto(_ cg: CGImage) {
        generation += 1
        let gen = generation
        photoStatus = "Распознаю текст…"
        isWorking = true
        errorText = nil
        let hints = [fromLanguage.vision, "en-US", "ru-RU"]
        DispatchQueue.global(qos: .userInitiated).async {
            let lines: [TranslateOCRLine]
            do {
                lines = try TranslateOCR.recognize(cg, hints: hints)
            } catch {
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.photoStatus = "Не удалось распознать текст"
                    self.isWorking = false
                }
                return
            }
            let pixels = TranslatePixels(cg)
            let blocks: [TranslateBlock] = lines.map { line in
                let c = pixels?.colors(for: line.rect) ?? (bg: TranslateRGB.white, fg: TranslateRGB.black)
                return TranslateBlock(rect: line.rect, original: line.text, translated: line.text, bg: c.bg.color, fg: c.fg.color)
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.blocks = blocks
                if blocks.isEmpty {
                    self.photoStatus = "Текст на картинке не найден"
                    self.isWorking = false
                    return
                }
                self.photoStatus = "Перевожу строк: \(blocks.count)…"
                self.translateBlocks(gen: gen)
            }
        }
    }

    private func translateBlocks(gen: Int) {
        let lines = blocks.map { $0.original }
        guard !lines.isEmpty else { return }
        isWorking = true
        let from = fromLanguage
        let to = toLanguage
        if Prefs.shared.translateEngine == .apple {
            startApple(.lines(lines), from: from, to: to)
            return
        }
        Task {
            do {
                let result = try await TranslateGoogle.translateLines(lines, from: "auto", to: to.google)
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.applyTranslatedLines(result)
                }
            } catch {
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.isWorking = false
                    if TranslateGoogle.isRateLimit(error), !from.apple.isEmpty, !to.apple.isEmpty {
                        self.startApple(.lines(lines), from: from, to: to)
                        return
                    }
                    self.photoStatus = "Не удалось перевести"
                    self.errorText = "Не удалось перевести: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyTranslatedLines(_ result: [String]) {
        for i in blocks.indices where i < result.count {
            blocks[i].translated = result[i]
        }
        isWorking = false
        photoStatus = "Готово · строк: \(blocks.count)"
    }

    var translatedText: String { blocks.map { $0.translated }.joined(separator: "\n") }

    static func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
