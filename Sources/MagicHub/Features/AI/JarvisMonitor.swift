import AppKit
import Combine

/// Снимок состояния Джарвиса (Claude Code в режиме каналов Telegram).
/// Устройство Джарвиса — docs/JARVIS_ARCHITECTURE.md.
struct JarvisState: Equatable {
    var found = false
    var running = false
    var pid: Int32?
    var uptime: TimeInterval?
    var pollers = 0
    var serviceLabel: String?
    var servicePlist: String?
    var serviceState: String?
    var lastExitCode: String?
    var botDir: String?
    var sessionFile: URL?

    var busy = false
    var lastActivity: Date?
    var currentTask: String?
    var taskStarted: Date?
    var firstReplyLatency: TimeInterval?
    var waitingFirstReply = false
    var contextTokens: Int?
    var lastError: String?
    var lastErrorCode: String?
    var lastErrorDate: Date?
    var errorsToday = 0
    var compactionsToday = 0
    var medianTurn: TimeInterval?
    var lastTurnDuration: TimeInterval?
    var restartsToday = 0
    /// Основной ход закончен, но фоновые агенты ещё пишут свои журналы.
    var background = false

    var lastIssue: JarvisIssue? { lastError.map { JarvisIssue.classify($0, code: lastErrorCode) } }

    /// Занят и тишина больше 10 минут — вероятно, завис.
    var hung: Bool {
        guard busy, let last = lastActivity else { return false }
        return Date().timeIntervalSince(last) > 600
    }
}

final class JarvisMonitor: ObservableObject {
    static let shared = JarvisMonitor()

    @Published private(set) var isBusy = false
    @Published private(set) var state = JarvisState()
    @Published private(set) var actionMessage: String?
    @Published private(set) var network: String?

    private let queue = DispatchQueue(label: "magichub.jarvis", qos: .utility)
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var initialized = false
    private var seenTaskDate: Date?
    private var seenErrorDate: Date?
    private var notifiedHang = false
    private var notRunningSince: Date?
    private var notifiedDown = false
    private var cachedLabel: (label: String, plist: String)?
    private var parseCache: (url: URL, size: UInt64, mtime: Date, result: SessionParse)?

    func start() {
        schedule()
        Prefs.shared.$aiInterval.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        Prefs.shared.$jarvisEnabled.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Prefs.shared.$jarvisBotDir.merge(with: Prefs.shared.$jarvisLabel, Prefs.shared.$jarvisHome).dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.cachedLabel = nil
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func schedule() {
        timer?.invalidate()
        refresh()
        let interval = max(5, Prefs.shared.aiInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard Prefs.shared.jarvisEnabled else {
            DispatchQueue.main.async {
                self.state = JarvisState()
                self.isBusy = false
            }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.collect()
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    // MARK: - Сбор данных

    private func collect() -> JarvisState {
        var s = JarvisState()

        // 1. Процессы: сама сессия и сервер плагина telegram.
        let ps = Shell.run("/bin/ps", ["-axo", "pid=,etime=,command="])
        var candidates: [(pid: Int32, etime: TimeInterval, exe: String)] = []
        var pollers = Set<Int32>()
        for line in ps.out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[2])
            let exe = (String(command.split(separator: " ").first ?? "") as NSString).lastPathComponent
            if command.contains("claude --channels") || (command.contains("claude") && command.contains("--channels")) {
                let shells = ["zsh", "bash", "sh", "script", "caffeinate", "-zsh", "login"]
                if !shells.contains(exe) {
                    candidates.append((pid, Self.parseEtime(String(parts[1])), exe))
                }
            }
            if command.contains("plugins/cache/claude-plugins-official/telegram/") && !["zsh", "bash", "sh"].contains(exe) {
                pollers.insert(pid)
            }
        }
        if let main = candidates.min(by: { $0.etime < $1.etime }) {
            s.running = true
            s.pid = main.pid
            s.uptime = main.etime
        }
        s.pollers = pollers.count

        // 2. Служба launchd.
        if let svc = serviceLabel() {
            s.serviceLabel = svc.label
            s.servicePlist = svc.plist
            let out = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(svc.label)"]).out
            for raw in out.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("state = ") { s.serviceState = String(line.dropFirst(8)) }
                if line.hasPrefix("last exit code = ") { s.lastExitCode = String(line.dropFirst(17)) }
            }
        }

        // 3. Рабочая папка бота → папка сессий Claude Code.
        var botDir = AppPaths.expand(Prefs.shared.jarvisBotDir)
        if Prefs.shared.jarvisBotDir.isEmpty {
            botDir = ""
            if let pid = s.pid {
                let lsof = Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).out
                if let n = lsof.split(separator: "\n").first(where: { $0.hasPrefix("n") }) {
                    botDir = String(n.dropFirst())
                }
            }
            if botDir.isEmpty {
                let def = AppPaths.home.appendingPathComponent("Jarvis/bot").path
                if FileManager.default.fileExists(atPath: def) { botDir = def }
            }
        }
        if !botDir.isEmpty { s.botDir = botDir }

        s.found = s.running || s.serviceLabel != nil || s.botDir != nil
        guard s.found else { return s }

        if let dir = s.botDir, let file = Self.latestSessionFile(forProject: dir) {
            s.sessionFile = file
            let parse = parseSession(file)
            s.busy = parse.busy
            s.lastActivity = parse.lastActivity
            if let bg = Self.lastBackgroundWrite(forProject: dir, session: file), Date().timeIntervalSince(bg) < 90 {
                s.background = !parse.busy
                s.busy = true
                if bg > (s.lastActivity ?? .distantPast) { s.lastActivity = bg }
            }
            s.currentTask = parse.lastTask
            s.taskStarted = parse.lastTaskDate
            s.firstReplyLatency = parse.firstReplyLatency
            s.waitingFirstReply = parse.waitingFirstReply
            s.contextTokens = parse.contextTokens
            s.lastError = parse.lastError
            s.lastErrorCode = parse.lastErrorCode
            s.lastErrorDate = parse.lastErrorDate
            s.errorsToday = parse.errorsToday
            s.compactionsToday = parse.compactionsToday
            s.medianTurn = parse.medianTurn
            s.lastTurnDuration = parse.lastTurnDuration
        }

        // 4. Перезапуски за сегодня — по ~/.jarvis/logs/bot.log.
        let log = URL(fileURLWithPath: AppPaths.expand(Prefs.shared.jarvisHome)).appendingPathComponent("logs/bot.log")
        if let text = Self.tail(of: log, bytes: 256 * 1024) {
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd"
            let f2 = DateFormatter(); f2.dateFormat = "dd.MM.yyyy"
            let f3 = DateFormatter(); f3.dateFormat = "dd.MM"
            let today = [f1.string(from: Date()), f2.string(from: Date()), f3.string(from: Date())]
            s.restartsToday = text.split(separator: "\n").filter { line in
                line.contains("запуск") && today.contains(where: { line.contains($0) })
            }.count
        }
        return s
    }

    /// Ищет службу launchd, которая запускает бота (run-bot или claude --channels).
    private func serviceLabel() -> (label: String, plist: String)? {
        if let cachedLabel { return cachedLabel }
        let dir = AppPaths.home.appendingPathComponent("Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let wanted = Prefs.shared.jarvisLabel
        var found: (String, String)?
        for f in files where f.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: f),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            if !wanted.isEmpty {
                if label == wanted { found = (label, f.path); break }
                continue
            }
            let args = (plist["ProgramArguments"] as? [String] ?? []).joined(separator: " ") + " " + (plist["Program"] as? String ?? "")
            if args.contains("run-bot") || args.contains("--channels") {
                found = (label, f.path)
                break
            }
        }
        cachedLabel = found
        return found
    }

    // MARK: - Разбор истории сессии (JSONL)

    struct SessionParse {
        var busy = false
        var lastActivity: Date?
        var lastTask: String?
        var lastTaskDate: Date?
        var firstReplyLatency: TimeInterval?
        var waitingFirstReply = false
        var contextTokens: Int?
        var lastError: String?
        var lastErrorCode: String?
        var lastErrorDate: Date?
        var errorsToday = 0
        var compactionsToday = 0
        var medianTurn: TimeInterval?
        var lastTurnDuration: TimeInterval?
    }

    private func parseSession(_ url: URL) -> SessionParse {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        if let c = parseCache, c.url == url, c.size == size, c.mtime == mtime {
            var r = c.result
            r.lastActivity = mtime
            return r
        }
        var r = SessionParse()
        r.lastActivity = mtime
        let window = 3 * 1024 * 1024
        guard let text = Self.tail(of: url, bytes: window) else { return r }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if size > UInt64(window), !lines.isEmpty { lines.removeFirst() }   // первая строка обрезана

        let cal = Calendar.current
        var lastActivityIndex = -1
        var lastTurnEndIndex = -1
        var turns: [Double] = []
        var replyAfterTask: Date?
        var index = 0

        for line in lines {
            index += 1
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            let date = (obj["timestamp"] as? String).flatMap(Self.parseDate)
            let message = obj["message"] as? [String: Any]

            if (obj["isApiErrorMessage"] as? Bool) == true || obj["error"] != nil {
                let msg = Self.text(of: message?["content"]) ?? (obj["error"] as? String) ?? "Ошибка API"
                r.lastError = String(msg.prefix(300))
                r.lastErrorCode = obj["error"] as? String
                r.lastErrorDate = date
                if let date, cal.isDateInToday(date) { r.errorsToday += 1 }
            }

            switch type {
            case "user":
                let content = message?["content"]
                if Self.isToolResult(content) {
                    lastActivityIndex = index
                    break
                }
                lastActivityIndex = index
                if let t = Self.text(of: content), let task = Self.channelText(t) {
                    r.lastTask = task
                    r.lastTaskDate = date
                    replyAfterTask = nil
                }
            case "assistant":
                lastActivityIndex = index
                if let usage = message?["usage"] as? [String: Any] {
                    let i = (usage["input_tokens"] as? Int) ?? 0
                    let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    if i + cr + cc > 0 { r.contextTokens = i + cr + cc }
                }
                if replyAfterTask == nil, r.lastTaskDate != nil, let blocks = message?["content"] as? [[String: Any]] {
                    let replied = blocks.contains { b in
                        (b["type"] as? String) == "tool_use" && ((b["name"] as? String) ?? "").hasSuffix("reply")
                    }
                    if replied { replyAfterTask = date }
                }
            case "system":
                let subtype = obj["subtype"] as? String ?? ""
                if subtype == "turn_duration" {
                    lastTurnEndIndex = index
                    if let ms = obj["durationMs"] as? Double {
                        turns.append(ms / 1000)
                        r.lastTurnDuration = ms / 1000
                    } else if let ms = obj["durationMs"] as? Int {
                        turns.append(Double(ms) / 1000)
                        r.lastTurnDuration = Double(ms) / 1000
                    }
                } else if subtype.contains("compact") {
                    if let date, cal.isDateInToday(date) { r.compactionsToday += 1 }
                }
            default:
                break
            }
        }

        r.busy = lastActivityIndex > lastTurnEndIndex && lastActivityIndex >= 0
        if let start = r.lastTaskDate {
            if let reply = replyAfterTask {
                r.firstReplyLatency = reply.timeIntervalSince(start)
            } else if r.busy {
                r.waitingFirstReply = true
                r.firstReplyLatency = Date().timeIntervalSince(start)
            }
        }
        let recent = Array(turns.suffix(20)).sorted()
        if !recent.isEmpty { r.medianTurn = recent[recent.count / 2] }

        parseCache = (url, size, mtime, r)
        return r
    }

    // MARK: - Применение и уведомления

    private func apply(_ s: JarvisState) {
        let prev = state
        state = s
        if isBusy != s.busy { isBusy = s.busy }

        defer { initialized = true }
        guard initialized else {
            seenTaskDate = s.taskStarted
            seenErrorDate = s.lastErrorDate
            return
        }
        let prefs = Prefs.shared

        if let d = s.taskStarted, d != seenTaskDate, d > (seenTaskDate ?? .distantPast) {
            seenTaskDate = d
            if prefs.evTaskTaken, Date().timeIntervalSince(d) < 600 {
                AppModel.shared.post(NotchNotification(title: "Джарвис принял задачу",
                                                       subtitle: "«\(Self.short(s.currentTask ?? ""))»",
                                                       kind: .progress))
            }
        }
        if prev.busy && !s.busy && prev.found && prefs.evTaskDone {
            let took = s.lastTurnDuration.map { "за " + Fmt.duration($0) } ?? ""
            AppModel.shared.post(NotchNotification(title: "Джарвис закончил задачу",
                                                   subtitle: [Self.short(s.currentTask ?? "", 40), took].filter { !$0.isEmpty }.joined(separator: " · "),
                                                   kind: .success))
        }
        if let d = s.lastErrorDate, d > (seenErrorDate ?? .distantPast) {
            seenErrorDate = d
            if prefs.evError, Date().timeIntervalSince(d) < 900 {
                let issue = JarvisIssue.classify(s.lastError ?? "", code: s.lastErrorCode)
                AppModel.shared.post(NotchNotification(title: issue.title,
                                                       subtitle: Self.short(issue.short, 70),
                                                       kind: issue.kind == .limit || issue.kind == .context ? .warning : .error))
            }
        }
        if s.hung && !notifiedHang {
            notifiedHang = true
            if prefs.evHang {
                let mins = Int(Date().timeIntervalSince(s.lastActivity ?? Date()) / 60)
                AppModel.shared.post(NotchNotification(title: "Джарвис, похоже, завис",
                                                       subtitle: "Нет активности \(mins) мин посреди задачи",
                                                       kind: .error))
            }
        } else if !s.hung {
            notifiedHang = false
        }
        if let old = prev.pid, let new = s.pid, old != new, prefs.evRestart {
            AppModel.shared.post(NotchNotification(title: "Джарвис перезапустился",
                                                   subtitle: s.lastExitCode.map { "Последний код выхода: \($0)" } ?? "",
                                                   kind: .info))
        }
        if s.found && !s.running {
            if notRunningSince == nil { notRunningSince = Date() }
            if !notifiedDown, let since = notRunningSince, Date().timeIntervalSince(since) > 60, prefs.evRestart {
                notifiedDown = true
                AppModel.shared.post(NotchNotification(title: "Джарвис не запущен",
                                                       subtitle: "Процесс не найден больше минуты",
                                                       kind: .error))
            }
        } else {
            notRunningSince = nil
            notifiedDown = false
        }
    }

    // MARK: - Управление

    /// Мягкий перезапуск через ~/.jarvis/bin/restart: бот продолжит задачу после перезапуска.
    func softRestart() {
        let script = URL(fileURLWithPath: AppPaths.expand(Prefs.shared.jarvisHome)).appendingPathComponent("bin/restart").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            setMessage("Нет скрипта \(script) — используйте жёсткий перезапуск")
            return
        }
        setMessage("Перезапускаю мягко…")
        queue.async {
            let r = Shell.run(script, ["Перезапуск из Magic Hub: продолжи то, что делал, если задача не закончена"])
            DispatchQueue.main.async {
                self.setMessage(r.ok ? "Перезапуск через ~10 с, Джарвис сам напишет «вернулся»" : "Не удалось: \(r.err.prefix(120))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.refresh() }
            }
        }
    }

    func hardRestart() {
        guard let label = state.serviceLabel else { setMessage("Служба Джарвиса не найдена"); return }
        launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"], done: "Жёсткий перезапуск выполнен")
    }

    func stopService() {
        guard let label = state.serviceLabel else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"], done: "Джарвис остановлен")
    }

    func startService() {
        guard let plist = state.servicePlist else { return }
        launchctl(["bootstrap", "gui/\(getuid())", plist], done: "Джарвис запущен")
    }

    private func launchctl(_ args: [String], done: String) {
        queue.async {
            let r = Shell.run("/bin/launchctl", args)
            DispatchQueue.main.async {
                self.setMessage(r.ok ? done : "Ошибка: \(r.err.isEmpty ? r.out : r.err)".trimmingCharacters(in: .whitespacesAndNewlines))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
            }
        }
    }

    func openLog() {
        let log = URL(fileURLWithPath: AppPaths.expand(Prefs.shared.jarvisHome)).appendingPathComponent("logs/bot.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            setMessage("Лог не найден: \(log.path)")
        }
    }

    /// Проверка сети: отдача (1 МБ на speed.cloudflare.com) и задержка до api.telegram.org.
    func checkNetwork() {
        network = "Проверяю сеть…"
        Task {
            var parts: [String] = []
            let pingStart = Date()
            var req = URLRequest(url: URL(string: "https://api.telegram.org")!)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 10
            if (try? await URLSession.shared.data(for: req)) != nil {
                parts.append("Telegram: \(Int(Date().timeIntervalSince(pingStart) * 1000)) мс")
            } else {
                parts.append("Telegram: нет ответа")
            }
            var up = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            up.httpMethod = "POST"
            up.timeoutInterval = 30
            let payload = Data(count: 1_000_000)
            let t0 = Date()
            if (try? await URLSession.shared.upload(for: up, from: payload)) != nil {
                let mbit = 8.0 / max(0.05, Date().timeIntervalSince(t0))
                parts.append("отдача \(Fmt.number(mbit, maxFraction: 1)) Мбит/с")
            } else {
                parts.append("отдача: ошибка")
            }
            let text = parts.joined(separator: " · ")
            await MainActor.run { self.network = text }
        }
    }

    private func setMessage(_ text: String) {
        actionMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.actionMessage == text { self?.actionMessage = nil }
        }
    }

    // MARK: - Помощники

    /// ~/.claude/projects/<путь, где всё кроме букв и цифр заменено на «-»>/<последний>.jsonl
    static func projectDir(for path: String) -> URL {
        let encoded = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return AppPaths.home.appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
    }

    static func latestSessionFile(forProject path: String) -> URL? {
        let dir = projectDir(for: path)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Фоновые агенты пишут журналы отдельно: `<сессия>/subagents/*.jsonl`
    /// (в старых версиях Claude Code — `agent-*.jsonl` рядом с сессией). Время последней записи.
    static func lastBackgroundWrite(forProject path: String, session: URL) -> Date? {
        let dir = projectDir(for: path)
        let fm = FileManager.default
        var latest: Date?
        func consider(_ url: URL) {
            guard url.pathExtension == "jsonl",
                  let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
            if d > (latest ?? .distantPast) { latest = d }
        }
        let sessionDir = dir.appendingPathComponent(session.deletingPathExtension().lastPathComponent)
        if let e = fm.enumerator(at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in e { consider(url) }
        }
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in top where url.lastPathComponent.hasPrefix("agent-") { consider(url) }
        return latest
    }

    static func tail(of url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// etime из ps: [[дд-]чч:]мм:сс
    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = String(s[s.index(after: dash)...])
        }
        let nums = rest.split(separator: ":").compactMap { Double($0) }
        var secs = 0.0
        for n in nums { secs = secs * 60 + n }
        return days * 86400 + secs
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }

    static func isToolResult(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "tool_result" }
    }

    static func text(of content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { b -> String? in
                (b["type"] as? String) == "text" ? b["text"] as? String : nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    /// Текст из <channel …>…</channel>.
    static func channelText(_ s: String) -> String? {
        guard let open = s.range(of: "<channel") else { return nil }
        guard let gt = s.range(of: ">", range: open.upperBound..<s.endIndex) else { return nil }
        let end = s.range(of: "</channel>", range: gt.upperBound..<s.endIndex)?.lowerBound ?? s.endIndex
        let body = s[gt.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "голосовое или файл" : String(body)
    }

    static func short(_ s: String, _ n: Int = 60) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }
}

/// Понятное объяснение ошибок Claude Code. «Лимит» — только настоящий лимит подписки,
/// а не любое сообщение со словом limit.
struct JarvisIssue {
    enum Kind { case limit, context, server, auth, network, other }

    let kind: Kind
    let title: String
    /// Для уведомления в чёлке.
    let short: String
    /// Что случилось и что делать — для карточки.
    let hint: String

    static func classify(_ text: String, code: String?) -> JarvisIssue {
        let t = text.lowercased()
        let c = (code ?? "").lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { t.contains($0) } }

        if has("autocompact is thrashing") {
            return JarvisIssue(kind: .context, title: "Контекст переполняется",
                               short: "Не лимит: контекст забивается сразу после сжатия",
                               hint: "Это не лимит подписки. После сжатия контекст снова заполнился за 3 хода, и так 3 раза подряд — Claude Code перестал сжимать его сам. Когда Джарвис свободен, нажмите «Мягкий перезапуск»: он начнёт свежую сессию.")
        }
        if has("prompt is too long", "context window", "context_length", "too many tokens") {
            return JarvisIssue(kind: .context, title: "Контекст переполнен",
                               short: "Нужна свежая сессия — мягкий перезапуск",
                               hint: "Разговор больше не помещается в контекст модели. Когда Джарвис свободен, нажмите «Мягкий перезапуск».")
        }
        if c == "rate_limit" || has("usage limit", "limit reached", "hit your limit", "rate_limit", "rate limit", "weekly limit") {
            return JarvisIssue(kind: .limit, title: "Кончился лимит Claude",
                               short: "Джарвис продолжит после сброса лимита",
                               hint: "Лимит подписки исчерпан. Когда он сбросится — видно на карточке Claude.")
        }
        if c == "billing_error" || has("credit balance", "billing") {
            return JarvisIssue(kind: .limit, title: "Проблема с оплатой Claude",
                               short: "Проверьте подписку на claude.ai",
                               hint: "Claude отказал из‑за оплаты. Проверьте подписку на claude.ai.")
        }
        if c == "authentication_failed" || has("/login", "oauth token", "invalid api key", "api error: 401", "authentication_error") {
            return JarvisIssue(kind: .auth, title: "Джарвис потерял вход в Claude",
                               short: "Нужно заново войти в Claude Code",
                               hint: "Токен входа истёк или отозван — Джарвису нужно заново войти в Claude Code, затем перезапустить его.")
        }
        if c == "server_error" || has("overloaded", "api error: 5", "internal server error") {
            return JarvisIssue(kind: .server, title: "Сбой на стороне Claude",
                               short: "Серверы Anthropic перегружены, лимит ни при чём",
                               hint: "Временная проблема у Anthropic, ваш лимит ни при чём. Обычно проходит сама за несколько минут.")
        }
        if has("connection error", "timed out", "timeout", "econnreset", "enotfound", "fetch failed", "network") {
            return JarvisIssue(kind: .network, title: "Нет связи с Claude",
                               short: "Проверьте интернет",
                               hint: "Запрос к Claude не дошёл. Проверьте интернет — кнопка с глобусом внизу замерит сеть.")
        }
        return JarvisIssue(kind: .other, title: "Ошибка у Джарвиса", short: text, hint: text)
    }
}
