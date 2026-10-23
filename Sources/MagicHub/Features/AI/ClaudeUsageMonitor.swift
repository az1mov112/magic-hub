import Foundation
import Combine

/// Лимит подписки (окно 5 часов, неделя…), как в /usage у Claude Code.
struct ClaudeLimit: Identifiable, Equatable {
    let id: String
    let title: String
    let utilization: Double      // 0…100
    let resetsAt: Date?
}

struct UsageTotals: Equatable, Codable {
    var input: Double = 0
    var output: Double = 0
    var cacheWrite: Double = 0
    var cacheRead: Double = 0
    var cost: Double = 0
    var tokens: Double { input + output + cacheWrite + cacheRead }

    static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheRead: a.cacheRead + b.cacheRead, cost: a.cost + b.cost)
    }
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    let name: String
    let busy: Bool
    let lastActivity: Date
    let isJarvis: Bool
}

/// Траты и лимиты Claude. Токены считаются по локальным логам Claude Code (~/.claude/projects),
/// стоимость — «сколько это стоило бы по ценам API» (на подписке Max за токены не списывают).
/// Лимиты — неофициальным способом (как /usage), через токен Claude Code из Связки ключей.
final class ClaudeUsageMonitor: ObservableObject {
    static let shared = ClaudeUsageMonitor()

    @Published private(set) var limits: [ClaudeLimit] = []
    @Published private(set) var limitsError: String?
    @Published private(set) var plan: String?
    @Published private(set) var today = UsageTotals()
    @Published private(set) var month = UsageTotals()
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var scanning = false

    private let queue = DispatchQueue(label: "magichub.claude-usage", qos: .utility)
    private var usageTimer: Timer?
    private var limitsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Состояние инкрементального сканирования (только на queue).
    // Сохраняется между запусками: журналы Claude Code за месяц — это сотни мегабайт,
    // перечитывать их после каждого обновления приложения слишком дорого.
    private var offsets: [String: UInt64] = [:]
    private var seenIDs = Set<String>()
    private var byDay: [String: UsageTotals] = [:]
    private var monthKey = ""
    private var cacheLoaded = false
    private var cacheDirty = false
    private var cacheSaved = Date.distantPast

    private struct UsageCache: Codable {
        var monthKey: String
        var offsets: [String: UInt64]
        var seenIDs: [String]
        var byDay: [String: UsageTotals]
    }

    private static let cacheURL = AppPaths.file("claude-usage-cache.json")

    private func loadCache() {
        cacheLoaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let c = try? JSONDecoder().decode(UsageCache.self, from: data) else { return }
        monthKey = c.monthKey
        offsets = c.offsets
        seenIDs = Set(c.seenIDs)
        byDay = c.byDay
    }

    private func saveCache(force: Bool = false) {
        guard cacheDirty, force || Date().timeIntervalSince(cacheSaved) > 300 else { return }
        let c = UsageCache(monthKey: monthKey, offsets: offsets, seenIDs: Array(seenIDs), byDay: byDay)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
        cacheDirty = false
        cacheSaved = Date()
    }

    func start() {
        refreshUsage()
        refreshLimits()
        scheduleUsage()
        Prefs.shared.$lite.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleUsage() }
            .store(in: &cancellables)
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refreshLimits() }
        Prefs.shared.$claudeLimits.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLimits() }
            .store(in: &cancellables)
    }

    /// Подсчёт расходов читает журналы Claude Code — в экономном режиме реже.
    private func scheduleUsage() {
        usageTimer?.invalidate()
        let interval: TimeInterval = Prefs.shared.lite ? 180 : 45
        usageTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshUsage() }
        usageTimer?.tolerance = interval * 0.2
    }

    /// При выходе из приложения — сохранить, докуда дочитаны журналы.
    func flush() {
        queue.sync { saveCache(force: true) }
    }

    func refreshAll() {
        refreshUsage()
        refreshLimits()
    }

    // MARK: - Лимиты подписки

    func refreshLimits() {
        guard Prefs.shared.claudeLimits else {
            limits = []
            limitsError = nil
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            guard r.ok, let data = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else {
                DispatchQueue.main.async { self.limitsError = "Нет входа в Claude Code на этом Mac" }
                return
            }
            let plan = oauth["subscriptionType"] as? String
            if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
                DispatchQueue.main.async {
                    self.plan = plan
                    self.limitsError = "Токен Claude Code устарел — обновится при следующем запуске Claude Code"
                }
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async {
                        self.plan = plan
                        self.limitsError = code == 0 ? "Нет связи с Anthropic" : "Лимиты недоступны (код \(code))"
                    }
                    return
                }
                let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
                var list: [ClaudeLimit] = []
                for (key, value) in obj {
                    guard let d = value as? [String: Any] else { continue }
                    let uDouble = d["utilization"] as? Double
                    let uInt = d["utilization"] as? Int
                    guard let u = uDouble ?? uInt.map({ Double($0) }) else { continue }
                    let reset = (d["resets_at"] as? String).flatMap(JarvisMonitor.parseDate)
                    list.append(ClaudeLimit(id: key, title: Self.limitTitle(key), utilization: u, resetsAt: reset))
                }
                list.sort { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
                DispatchQueue.main.async {
                    self.plan = plan
                    self.limits = list
                    self.limitsError = list.isEmpty ? "Лимиты не пришли" : nil
                }
            }.resume()
        }
    }

    private static func limitTitle(_ key: String) -> String {
        switch key {
        case "five_hour": return "Сессия (окно 5 ч)"
        case "seven_day": return "Неделя"
        case "seven_day_opus": return "Неделя · Opus"
        case "seven_day_sonnet": return "Неделя · Sonnet"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Токены и стоимость по логам

    func refreshUsage() {
        queue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.scanning = true }
            let (todayTotals, monthTotals, active) = self.scan()
            DispatchQueue.main.async {
                self.today = todayTotals
                self.month = monthTotals
                self.sessions = active
                self.scanning = false
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func scan() -> (UsageTotals, UsageTotals, [ClaudeSession]) {
        let now = Date()
        let cal = Calendar.current
        let mk = String(Self.dayFormatter.string(from: now).prefix(7))
        if !cacheLoaded { loadCache() }
        if mk != monthKey {   // новый месяц — считаем заново
            monthKey = mk
            offsets = [:]
            seenIDs = []
            byDay = [:]
            cacheDirty = true
        }
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let root = AppPaths.home.appendingPathComponent(".claude/projects")
        var active: [ClaudeSession] = []
        let jarvisFile = JarvisMonitor.shared.state.sessionFile?.path

        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else {
            return (UsageTotals(), UsageTotals(), [])
        }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = v.contentModificationDate, mtime >= startOfMonth else { continue }
            let size = UInt64(v.fileSize ?? 0)
            let path = url.path
            var from = offsets[path] ?? 0
            if size < from { from = 0 }   // файл перезаписан — дочитаем заново, повторы отсеет seenIDs
            if size > from {
                offsets[path] = readUsage(url, from: from, to: size, monthStart: startOfMonth)
                cacheDirty = true
            }
            if now.timeIntervalSince(mtime) < 180, !path.contains("/subagents/") {
                active.append(sessionInfo(url, mtime: mtime, isJarvis: path == jarvisFile))
            }
        }
        saveCache()
        let todayTotals = byDay[Self.dayFormatter.string(from: now)] ?? UsageTotals()
        let monthTotals = byDay.filter { $0.key.hasPrefix(mk) }.values.reduce(UsageTotals(), +)
        active.sort { $0.lastActivity > $1.lastActivity }
        return (todayTotals, monthTotals, Array(active.prefix(5)))
    }

    private static let usageKey = Data("\"usage\"".utf8)
    private static let assistantKey = Data("\"type\":\"assistant\"".utf8)

    /// Читает новые полные строки файла кусками по 4 МБ, возвращает смещение, до которого дочитано.
    private func readUsage(_ url: URL, from: UInt64, to: UInt64, monthStart: Date) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return from }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        var consumed = from          // до сюда разобраны целые строки
        var readPos = from           // до сюда прочитано
        var carry = Data()
        while readPos < to {
            let want = Int(min(UInt64(4 * 1024 * 1024), to - readPos))
            guard let data = try? h.read(upToCount: want), !data.isEmpty else { break }
            readPos += UInt64(data.count)
            carry.append(data)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else {
                if carry.count > 64 * 1024 * 1024 {   // гигантская строка без конца — пропускаем
                    consumed += UInt64(carry.count)
                    carry = Data()
                }
                continue
            }
            let complete = carry[carry.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) {
                // Быстрый отсев без разбора JSON: нужны только ответы модели с usage.
                guard line.range(of: Self.usageKey) != nil, line.range(of: Self.assistantKey) != nil else { continue }
                consumeUsage(Data(line), monthStart: monthStart)
            }
            consumed += UInt64(complete.count)
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        return consumed
    }

    private func consumeUsage(_ line: Data, monthStart: Date) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>" else { return }
        let id = (message["id"] as? String ?? "") + ":" + (obj["requestId"] as? String ?? "")
        if id.count > 1 {
            if seenIDs.contains(id) { return }
            seenIDs.insert(id)
        }
        guard let ts = (obj["timestamp"] as? String).flatMap(JarvisMonitor.parseDate), ts >= monthStart else { return }

        let num: (String) -> Double = { key in
            if let d = usage[key] as? Double { return d }
            if let i = usage[key] as? Int { return Double(i) }
            return 0
        }
        let input = num("input_tokens")
        let output = num("output_tokens")
        let read = num("cache_read_input_tokens")
        let write = num("cache_creation_input_tokens")
        var write5m = write, write1h = 0.0
        if let cc = usage["cache_creation"] as? [String: Any] {
            let a = (cc["ephemeral_5m_input_tokens"] as? Double) ?? Double((cc["ephemeral_5m_input_tokens"] as? Int) ?? 0)
            let b = (cc["ephemeral_1h_input_tokens"] as? Double) ?? Double((cc["ephemeral_1h_input_tokens"] as? Int) ?? 0)
            if a + b > 0 { write5m = a; write1h = b }
        }
        let p = Self.price(model)
        let cost = (input * p.input + output * p.output + read * p.read + write5m * p.input * 1.25 + write1h * p.input * 2) / 1_000_000
        let day = Self.dayFormatter.string(from: ts)
        byDay[day, default: UsageTotals()] = byDay[day, default: UsageTotals()] + UsageTotals(input: input, output: output, cacheWrite: write, cacheRead: read, cost: cost)
    }

    /// Цены API, USD за 1 млн токенов (input, output, cache read). Запись в кэш: 1,25× (5 мин) и 2× (1 ч) от input.
    static func price(_ model: String) -> (input: Double, output: Double, read: Double) {
        let m = model.lowercased()
        if m.contains("fable-5-1") || m.contains("mythos-5-1") { return (10, 50, 0.25) }
        if m.contains("fable") || m.contains("mythos") { return (10, 50, 1.0) }
        if m.contains("opus-5-5") { return (4, 20, 0.20) }
        if m.contains("opus-4-1") || m.contains("opus-4-2025") || m.hasSuffix("opus-4") || m.contains("opus-4-0") { return (15, 75, 1.5) }
        if m.contains("opus") { return (5, 25, 0.5) }
        if m.contains("sonnet-5") { return (2, 10, 0.2) }
        if m.contains("sonnet") { return (3, 15, 0.3) }
        if m.contains("haiku-5") { return (0.1, 0.5, 0.01) }
        if m.contains("haiku-4") { return (1, 5, 0.1) }
        if m.contains("haiku") { return (0.8, 4, 0.08) }
        return (3, 15, 0.3)
    }

    private func sessionInfo(_ url: URL, mtime: Date, isJarvis: Bool) -> ClaudeSession {
        var name = url.deletingLastPathComponent().lastPathComponent
        var busy = false
        if let text = JarvisMonitor.tail(of: url, bytes: 256 * 1024) {
            var lastActivity = -1, lastEnd = -1, i = 0
            for line in text.split(separator: "\n") {
                i += 1
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let cwd = obj["cwd"] as? String { name = (cwd as NSString).lastPathComponent }
                switch obj["type"] as? String {
                case "user", "assistant": lastActivity = i
                case "system": if (obj["subtype"] as? String) == "turn_duration" { lastEnd = i }
                default: break
                }
            }
            busy = lastActivity > lastEnd
        }
        return ClaudeSession(id: url.path, name: isJarvis ? "Джарвис" : name, busy: busy, lastActivity: mtime, isJarvis: isJarvis)
    }
}
