import AppKit
import Combine

/// То, что сейчас играет на Mac (любой источник: Telegram, браузер, Яндекс Музыка, Spotify…).
/// Данные приходят от `/usr/bin/perl Resources/mediaremote.pl libMediaRemoteBridge.dylib stream`
/// построчно в JSON — так обходится закрытие MediaRemote для сторонних приложений (macOS 15.4+).
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var timestamp = Date()
    @Published private(set) var rate: Double = 0
    @Published private(set) var bundleID: String?
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceIcon: NSImage?
    /// Мост к системному «Сейчас играет» запущен.
    @Published private(set) var available = false

    var hasContent: Bool { !title.isEmpty }

    private var process: Process?
    private var buffer = Data()
    private var stopped = true
    private var lastLaunch = Date.distantPast
    private var relaunchScheduled = false
    private let ioQueue = DispatchQueue(label: "app.magichub.nowplaying.io")
    /// Между треками источник на долю секунды присылает «пусто» или паузу — такое состояние
    /// придерживаем, чтобы чёлка и вкладка не мигали. Настоящая пауза применится через миг.
    private var held: (o: [String: Any], artwork: NSImage?, mode: Int)?
    private var holdWork: DispatchWorkItem?
    /// Новый трек пришёл без обложки — старую убираем не сразу: обложка обычно догоняет.
    private var artworkClearWork: DispatchWorkItem?

    private var scriptURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("mediaremote.pl") }
    private var libraryURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("libMediaRemoteBridge.dylib") }

    private var bridgeFiles: (script: String, lib: String)? {
        guard let s = scriptURL?.path, let l = libraryURL?.path,
              FileManager.default.fileExists(atPath: s),
              FileManager.default.fileExists(atPath: l) else { return nil }
        return (s, l)
    }

    // MARK: Запуск и остановка

    func start() {
        DispatchQueue.main.async {
            self.stopped = false
            self.launch()
        }
    }

    func stop() {
        stopped = true
        let p = process
        process = nil
        if let p, p.isRunning { p.terminate() }
        available = false
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let files = bridgeFiles else { return }   // запуск без бандла — тихо ничего не показываем

        let since = Date().timeIntervalSince(lastLaunch)
        if since < 5 {
            guard !relaunchScheduled else { return }
            relaunchScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (5 - since)) { [weak self] in
                self?.relaunchScheduled = false
                self?.launch()
            }
            return
        }
        lastLaunch = Date()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.lib, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        ioQueue.async { self.buffer.removeAll() }

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.process === proc { self.process = nil }
                self.available = false
                if !self.stopped { self.launch() }
            }
        }
        do {
            try p.run()
            process = p
            available = true
        } catch {
            process = nil
            available = false
        }
    }

    // MARK: Разбор строк JSON

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            var newArtwork: NSImage?
            var artworkMode = 0   // 0 — нет обложки, 1 — прежняя, 2 — новая
            if let base64 = object["artwork"] as? String,
               let bytes = Data(base64Encoded: base64),
               let image = NSImage(data: bytes) {
                newArtwork = image
                artworkMode = 2
            } else if (object["artworkUnchanged"] as? Bool) == true {
                artworkMode = 1
            }
            DispatchQueue.main.async { [weak self] in
                self?.apply(object, artwork: newArtwork, artworkMode: artworkMode)
            }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }   // защита от мусора без переводов строки
    }

    private func apply(_ o: [String: Any], artwork incomingArtwork: NSImage?, artworkMode incomingMode: Int, force: Bool = false) {
        func num(_ key: String) -> Double { (o[key] as? NSNumber)?.doubleValue ?? 0 }

        // Обложка могла прийти в придержанном сообщении, а это лишь говорит «не изменилась».
        var newArtwork = incomingArtwork
        var artworkMode = incomingMode
        if artworkMode == 1, let h = held, h.mode == 2 {
            newArtwork = h.artwork
            artworkMode = 2
        }

        let newTitle = (o["title"] as? String) ?? ""
        let reportedPlaying = (o["isPlaying"] as? Bool) ?? (num("playbackRate") > 0)
        if !force, isPlaying, hasContent, newTitle.isEmpty || !reportedPlaying {
            held = (o, newArtwork, artworkMode)
            if holdWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let h = self.held else { return }
                    self.holdWork = nil
                    self.held = nil
                    self.apply(h.o, artwork: h.artwork, artworkMode: h.mode, force: true)
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
            }
            return
        }
        holdWork?.cancel()
        holdWork = nil
        held = nil

        let titleChanged = title != newTitle
        if titleChanged { title = newTitle }
        let newArtist = (o["artist"] as? String) ?? ""
        if artist != newArtist { artist = newArtist }
        let newAlbum = (o["album"] as? String) ?? ""
        if album != newAlbum { album = newAlbum }

        duration = num("duration")
        elapsed = num("elapsed")
        rate = num("playbackRate")
        if let ts = o["timestamp"] as? NSNumber {
            timestamp = Date(timeIntervalSince1970: ts.doubleValue)
        } else {
            timestamp = Date()
        }

        let reported = (o["isPlaying"] as? Bool) ?? (rate > 0)
        let playing = reported && !newTitle.isEmpty
        if isPlaying != playing { isPlaying = playing }

        switch artworkMode {
        case 2:
            artworkClearWork?.cancel()
            artworkClearWork = nil
            artwork = newArtwork
        case 1:
            break
        default:
            if artwork != nil && artworkClearWork == nil {
                if titleChanged && !newTitle.isEmpty {
                    let work = DispatchWorkItem { [weak self] in
                        self?.artworkClearWork = nil
                        self?.artwork = nil
                    }
                    artworkClearWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
                } else {
                    artwork = nil
                }
            }
        }

        let parent = (o["parentBundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let own = (o["bundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bid = parent ?? own
        if bid != bundleID {
            bundleID = bid
            resolveSource(bid)
        }
    }

    private func resolveSource(_ bid: String?) {
        guard let bid else {
            sourceName = ""
            sourceIcon = nil
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            sourceName = name
            sourceIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            sourceName = MusicKnownSources.name(for: bid)
            sourceIcon = nil
        }
    }

    // MARK: Время и команды

    /// Текущая позиция с учётом хода времени после последнего обновления.
    func currentElapsed(at date: Date = Date()) -> Double {
        var e = elapsed
        if isPlaying && rate > 0 {
            e += date.timeIntervalSince(timestamp) * rate
        }
        if duration > 0 { e = min(e, duration) }
        return max(0, e)
    }

    func togglePlayPause() {
        send(command: 2)
        // Оптимистично, чтобы кнопка отреагировала сразу; мост пришлёт точное состояние.
        if hasContent {
            elapsed = currentElapsed()
            timestamp = Date()
            isPlaying.toggle()
        }
    }

    func next() { send(command: 4) }
    func previous() { send(command: 5) }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        runSend(env: ["MH_SEEK": String(format: "%.3f", target)])
        elapsed = target
        timestamp = Date()
    }

    private func send(command: Int) {
        runSend(env: ["MH_COMMAND": String(command)])
    }

    private func runSend(env: [String: String]) {
        guard let files = bridgeFiles else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.run("/usr/bin/perl", [files.script, files.lib, "send"], env: env)
        }
    }
}

/// Имена для источников, которые не являются обычными приложениями.
enum MusicKnownSources {
    static func name(for bundleID: String) -> String {
        let map: [String: String] = [
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Google Chrome",
            "ru.keepcoder.Telegram": "Telegram",
            "com.tdesktop.Telegram": "Telegram",
            "com.spotify.client": "Spotify",
            "com.apple.Music": "Музыка",
            "com.apple.podcasts": "Подкасты",
            "com.apple.TV": "TV"
        ]
        if let n = map[bundleID] { return n }
        if bundleID.hasPrefix("com.apple.WebKit") { return "Браузер" }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
