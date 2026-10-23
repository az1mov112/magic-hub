import Foundation
import SwiftUI

struct NotionTask: Identifiable, Equatable {
    let id: String
    let url: String
    var title: String
    var due: Date?
    var dueHasTime: Bool
    var status: String?
    var priority: String?
    var sphere: String?
    var project: String?
}

struct NotionOption: Hashable {
    let name: String
    let color: String
}

/// Какие поля базы за что отвечают (определяется по имени, запасной вариант — по типу).
struct NotionSchema {
    var titleProp: String?
    var dateProp: String?
    var statusProp: String?
    var statusType: String = "select"
    var statusOptions: [NotionOption] = []
    var priorityProp: String?
    var priorityOptions: [NotionOption] = []
    var sphereProp: String?
    var sphereOptions: [NotionOption] = []
    var projectProp: String?
    var projectOptions: [NotionOption] = []
}

enum NotionError: LocalizedError {
    case notConfigured
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Notion не настроен"
        case .message(let m): return m
        }
    }
}

/// Задачи из базы Notion (та, куда Джарвис записывает задачи).
final class NotionService: ObservableObject {
    static let shared = NotionService()
    static let tokenAccount = "notion.token"

    @Published private(set) var tasks: [NotionTask] = []
    @Published private(set) var schema: NotionSchema?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdate: Date?
    /// Задачи, отмеченные выполненными в этой сессии: остаются в списке, чтобы можно было снять галочку.
    @Published private(set) var locallyDone: Set<String> = []

    private var previousStatus: [String: String] = [:]

    var token: String? {
        guard let t = Keychain.get(NotionService.tokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    var databaseID: String? { NotionService.extractID(Prefs.shared.notionDatabase) }
    var isConfigured: Bool { token != nil && databaseID != nil }

    // MARK: Загрузка

    func refresh(force: Bool = true) {
        if !force, let last = lastUpdate, Date().timeIntervalSince(last) < 60 { return }
        guard let token, let dbID = databaseID else { return }
        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                let ds = NotionService.dataSourceID
                let base = ds.map { "data_sources/\($0)" } ?? "databases/\(dbID)"
                let version = ds == nil ? "2022-06-28" : NotionService.newAPI
                let schemaJSON = try await self.request(base, token: token, version: version)
                let schema = NotionService.parseSchema(schemaJSON)
                var pages: [[String: Any]] = []
                var cursor: String?
                repeat {
                    var body: [String: Any] = ["page_size": 100]
                    if let cursor { body["start_cursor"] = cursor }
                    let res = try await self.request("\(base)/query", method: "POST", body: body, token: token, version: version)
                    pages += (res["results"] as? [[String: Any]]) ?? []
                    cursor = (res["has_more"] as? Bool) == true ? res["next_cursor"] as? String : nil
                } while cursor != nil && pages.count < 2000
                let tasks = pages.compactMap { NotionService.parseTask($0, schema: schema) }
                await MainActor.run {
                    self.schema = schema
                    self.tasks = tasks
                    self.locallyDone = []
                    self.error = nil
                    self.lastUpdate = Date()
                    self.isLoading = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.error = message
                    self.isLoading = false
                }
            }
        }
    }

    /// Проверка подключения для настроек: (успех, текст).
    func testConnection() async -> (Bool, String) {
        guard let token else { return (false, "Сначала сохраните токен") }
        if let id = databaseID {
            // а) классический API
            if let json = try? await request("databases/\(id)", token: token) {
                NotionService.dataSourceID = nil
                let title = NotionService.plainTitle(json["title"])
                await MainActor.run { self.refresh(force: true) }
                return (true, "Подключено: «\(title.isEmpty ? "база задач" : title)»")
            }
            // б) новый API: база → её источник данных
            if let json = try? await request("databases/\(id)", token: token, version: NotionService.newAPI),
               let ds = (json["data_sources"] as? [[String: Any]])?.first, let dsID = ds["id"] as? String {
                NotionService.dataSourceID = dsID
                let title = NotionService.plainTitle(json["title"])
                await MainActor.run { self.refresh(force: true) }
                return (true, "Подключено: «\(title.isEmpty ? (ds["name"] as? String ?? "база задач") : title)»")
            }
        }
        // Ссылка не подошла — что интеграция вообще видит?
        let found = await accessibleDatabases(token: token)
        if let pick = NotionService.pickTasksDatabase(found) {
            return await adopt(pick, token: token, note: databaseID == nil ? "Нашёл базу" : "Ссылка не подошла, но я нашёл базу")
        }
        if !found.isEmpty {
            let names = found.prefix(4).map { "«\($0.title)»" }.joined(separator: ", ")
            return (false, "Эта база недоступна. Интеграция видит: \(names). Вставьте ссылку на нужную или выдайте доступ к ней")
        }
        let pages = await visiblePagesCount(token: token)
        if pages > 0 {
            return (false, "Интеграция видит \(pages) стр., но ни одной базы. Выдайте доступ именно к странице, внутри которой лежит база «Задачи» (••• → Connections → Magic Hub)")
        }
        return (false, "Интеграция не видит в Notion ничего: доступ не выдан. Откройте страницу с задачами → ••• (справа вверху) → в поиске меню «connect» → Magic Hub → Confirm")
    }

    static let newAPI = "2025-09-03"

    /// ID источника данных (новый API Notion), если база подключена через него.
    static var dataSourceID: String? {
        get { UserDefaults.standard.string(forKey: "notion.dataSourceID") }
        set { UserDefaults.standard.set(newValue, forKey: "notion.dataSourceID") }
    }

    private struct FoundDatabase {
        let id: String
        let title: String
        let url: String
        let dataSourceID: String?
    }

    private func accessibleDatabases(token: String) async -> [FoundDatabase] {
        var list: [FoundDatabase] = []
        let oldBody: [String: Any] = ["filter": ["property": "object", "value": "database"], "page_size": 50]
        if let json = try? await request("search", method: "POST", body: oldBody, token: token) {
            for r in (json["results"] as? [[String: Any]]) ?? [] {
                guard let id = r["id"] as? String else { continue }
                list.append(FoundDatabase(id: id, title: NotionService.plainTitle(r["title"]), url: (r["url"] as? String) ?? id, dataSourceID: nil))
            }
        }
        if !list.isEmpty { return list }
        let newBody: [String: Any] = ["filter": ["property": "object", "value": "data_source"], "page_size": 50]
        if let json = try? await request("search", method: "POST", body: newBody, token: token, version: NotionService.newAPI) {
            for r in (json["results"] as? [[String: Any]]) ?? [] {
                guard let id = r["id"] as? String else { continue }
                let parent = r["parent"] as? [String: Any]
                let dbID = (parent?["database_id"] as? String) ?? id
                let title = NotionService.plainTitle(r["title"])
                list.append(FoundDatabase(id: dbID, title: title.isEmpty ? (r["name"] as? String ?? "") : title,
                                          url: (r["url"] as? String) ?? dbID, dataSourceID: id))
            }
        }
        return list
    }

    private func visiblePagesCount(token: String) async -> Int {
        let body: [String: Any] = ["page_size": 20]
        guard let json = try? await request("search", method: "POST", body: body, token: token) else { return 0 }
        return ((json["results"] as? [[String: Any]]) ?? []).count
    }

    /// База задач: с «Задач» / «Task» в названии, иначе — единственная доступная.
    private static func pickTasksDatabase(_ list: [FoundDatabase]) -> FoundDatabase? {
        if let named = list.first(where: { $0.title.lowercased().contains("задач") || $0.title.lowercased().contains("task") }) { return named }
        return list.count == 1 ? list[0] : nil
    }

    private func adopt(_ db: FoundDatabase, token: String, note: String) async -> (Bool, String) {
        NotionService.dataSourceID = db.dataSourceID
        await MainActor.run {
            Prefs.shared.notionDatabase = db.url
            self.refresh(force: true)
        }
        return (true, "\(note) «\(db.title)» и подключил")
    }

    private static func plainTitle(_ raw: Any?) -> String {
        ((raw as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    // MARK: Галочка «выполнено»

    func isClosed(_ task: NotionTask) -> Bool { NotionService.isClosedStatus(task.status) }

    func toggleDone(_ task: NotionTask) {
        guard let schema, let statusProp = schema.statusProp else {
            AppModel.shared.flash("В базе нет поля статуса")
            return
        }
        guard let token, let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let wasClosed = isClosed(tasks[index])
        let old = tasks[index].status
        let newStatus: String
        if wasClosed {
            newStatus = previousStatus[task.id] ?? NotionService.reopenName(schema)
        } else {
            previousStatus[task.id] = (old != nil && !NotionService.isClosedStatus(old)) ? old! : NotionService.reopenName(schema)
            newStatus = NotionService.doneName(schema)
            locallyDone.insert(task.id)
        }
        tasks[index].status = newStatus

        let value: [String: Any] = schema.statusType == "status" ? ["status": ["name": newStatus]] : ["select": ["name": newStatus]]
        let body: [String: Any] = ["properties": [statusProp: value]]
        Task {
            do {
                _ = try await self.request("pages/\(task.id)", method: "PATCH", body: body, token: token)
                await MainActor.run { AppModel.shared.flash(wasClosed ? "Задача снова открыта" : "Готово ✓") }
            } catch {
                await MainActor.run {
                    if let j = self.tasks.firstIndex(where: { $0.id == task.id }) { self.tasks[j].status = old }
                    AppModel.shared.flash("Не удалось обновить Notion")
                }
            }
        }
    }

    // MARK: Папки

    /// Задачи папки: невыполненные + отмеченные в этой сессии.
    func tasks(in folder: String) -> [NotionTask] {
        tasks
            .filter { (!isClosed($0) || locallyDone.contains($0.id)) && NotionService.matches($0, folder: folder) }
            .sorted(by: NotionService.order)
    }

    func count(in folder: String) -> Int {
        tasks.filter { !isClosed($0) && NotionService.matches($0, folder: folder) }.count
    }

    static func matches(_ t: NotionTask, folder: String) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch folder {
        case "today":
            guard let d = t.due else { return false }
            return cal.isDateInToday(d)
        case "upcoming":
            guard let d = t.due else { return false }
            let day = cal.startOfDay(for: d)
            guard let limit = cal.date(byAdding: .day, value: 7, to: today) else { return false }
            return day > today && day <= limit
        case "overdue":
            guard let d = t.due else { return false }
            return cal.startOfDay(for: d) < today
        case "nodate":
            return t.due == nil
        case "all":
            return true
        default:
            if folder.hasPrefix("s:") { return t.sphere == String(folder.dropFirst(2)) }
            if folder.hasPrefix("p:") { return t.project == String(folder.dropFirst(2)) }
            return false
        }
    }

    static func order(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let pa = priorityRank(a.priority), pb = priorityRank(b.priority)
        if pa != pb { return pa < pb }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }

    // MARK: Оформление

    static func priorityRank(_ p: String?) -> Int {
        guard let p = p?.lowercased() else { return 1 }
        if p.contains("сроч") || p.contains("high") || p.contains("urgent") || p.contains("🔥") || p.contains("высок") { return 0 }
        if p.contains("когда") || p.contains("low") || p.contains("someday") || p.contains("низк") { return 2 }
        return 1
    }

    static func priorityColor(_ p: String?) -> Color {
        switch priorityRank(p) {
        case 0: return MH.red
        case 2: return Color(hex: "48484A")
        default: return MH.t3
        }
    }

    /// Убирает эмодзи из названия варианта («🔥 Срочно» → «Срочно»).
    static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { u in
            !(u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value >= 0x2190) || u.value == 0xFE0F || u.value == 0x200D)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    static func color(named name: String) -> Color {
        switch name {
        case "blue": return MH.lightBlue
        case "purple": return MH.purple
        case "pink": return MH.pink
        case "green": return MH.green
        case "red": return MH.red
        case "orange": return MH.orange
        case "yellow": return MH.yellow
        case "brown": return Color(hex: "B08968")
        default: return MH.t2
        }
    }

    func sphereColor(_ name: String?) -> Color {
        guard let name, let opt = schema?.sphereOptions.first(where: { $0.name == name }) else { return MH.t2 }
        return NotionService.color(named: opt.color)
    }

    func projectColor(_ name: String?) -> Color {
        guard let name, let opt = schema?.projectOptions.first(where: { $0.name == name }) else { return MH.t2 }
        return NotionService.color(named: opt.color)
    }

    static func dueText(_ t: NotionTask) -> String? {
        guard let d = t.due else { return nil }
        let cal = Calendar.current
        var time = ""
        if t.dueHasTime {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            time = ", " + f.string(from: d)
        }
        if cal.isDateInToday(d) { return "Сегодня" + time }
        if cal.isDateInTomorrow(d) { return "Завтра" + time }
        if cal.isDateInYesterday(d) { return "Вчера" + time }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE, d MMM"
        let s = f.string(from: d)
        return s.prefix(1).uppercased() + String(s.dropFirst()) + time
    }

    static func isOverdue(_ t: NotionTask) -> Bool {
        guard let d = t.due else { return false }
        return Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: Date())
    }

    // MARK: Статусы

    static func isClosedStatus(_ s: String?) -> Bool {
        guard let s = s?.lowercased() else { return false }
        return s.contains("готов") || s.contains("выполн") || s.contains("done") || s.contains("complete")
            || s.contains("отмен") || s.contains("cancel") || s.contains("заверш")
    }

    static func doneName(_ schema: NotionSchema) -> String {
        if let o = schema.statusOptions.first(where: { o in
            let n = o.name.lowercased()
            return n.contains("готов") || n.contains("done") || n.contains("выполн") || n.contains("complete")
        }) { return o.name }
        return "Готово"
    }

    static func reopenName(_ schema: NotionSchema) -> String {
        schema.statusOptions.first(where: { !isClosedStatus($0.name) })?.name ?? "К выполнению"
    }

    // MARK: Разбор ответов Notion

    static func parseSchema(_ json: [String: Any]) -> NotionSchema {
        let props = (json["properties"] as? [String: Any]) ?? [:]
        func type(_ name: String) -> String? { (props[name] as? [String: Any])?["type"] as? String }
        func options(_ name: String?) -> [NotionOption] {
            guard let name, let p = props[name] as? [String: Any], let t = p["type"] as? String,
                  let inner = p[t] as? [String: Any], let opts = inner["options"] as? [[String: Any]] else { return [] }
            return opts.compactMap { o in
                guard let n = o["name"] as? String else { return nil }
                return NotionOption(name: n, color: (o["color"] as? String) ?? "default")
            }
        }
        func find(_ names: [String], types: [String]) -> String? {
            for n in names {
                if let t = type(n), types.contains(t) { return n }
            }
            let lower = names.map { $0.lowercased() }
            for key in props.keys.sorted() where lower.contains(key.lowercased()) {
                if let t = type(key), types.contains(t) { return key }
            }
            return nil
        }
        func firstOfType(_ t: String) -> String? { props.keys.sorted().first(where: { type($0) == t }) }

        var s = NotionSchema()
        s.titleProp = firstOfType("title")
        s.dateProp = find(["Срок", "Дата", "Дедлайн", "Due", "Due date", "Date", "Deadline"], types: ["date"]) ?? firstOfType("date")
        s.statusProp = find(["Статус", "Status", "Состояние"], types: ["select", "status"]) ?? firstOfType("status")
        if let sp = s.statusProp {
            s.statusType = type(sp) ?? "select"
            s.statusOptions = options(sp)
        }
        s.priorityProp = find(["Приоритет", "Priority", "Важность"], types: ["select", "status"])
        s.priorityOptions = options(s.priorityProp)
        s.sphereProp = find(["Сфера", "Область", "Категория", "Area", "Category"], types: ["select", "multi_select"])
        s.sphereOptions = options(s.sphereProp)
        s.projectProp = find(["Проект", "Project"], types: ["select", "multi_select"])
        s.projectOptions = options(s.projectProp)
        return s
    }

    static func parseTask(_ page: [String: Any], schema: NotionSchema) -> NotionTask? {
        guard let id = page["id"] as? String else { return nil }
        if (page["archived"] as? Bool) == true || (page["in_trash"] as? Bool) == true { return nil }
        let props = (page["properties"] as? [String: Any]) ?? [:]
        func prop(_ name: String?) -> [String: Any]? {
            guard let name else { return nil }
            return props[name] as? [String: Any]
        }
        func text(_ p: [String: Any]?) -> String? {
            guard let p, let t = p["type"] as? String else { return nil }
            switch t {
            case "title", "rich_text":
                let arr = (p[t] as? [[String: Any]]) ?? []
                let s = arr.compactMap { $0["plain_text"] as? String }.joined()
                return s.isEmpty ? nil : s
            case "select", "status":
                return (p[t] as? [String: Any])?["name"] as? String
            case "multi_select":
                return ((p[t] as? [[String: Any]])?.first)?["name"] as? String
            default:
                return nil
            }
        }
        var due: Date?
        var hasTime = false
        if let p = prop(schema.dateProp), let d = p["date"] as? [String: Any], let start = d["start"] as? String {
            let parsed = parseDate(start)
            due = parsed.0
            hasTime = parsed.1
        }
        return NotionTask(id: id,
                          url: (page["url"] as? String) ?? "",
                          title: text(prop(schema.titleProp)) ?? "Без названия",
                          due: due,
                          dueHasTime: hasTime,
                          status: text(prop(schema.statusProp)),
                          priority: text(prop(schema.priorityProp)),
                          sphere: text(prop(schema.sphereProp)),
                          project: text(prop(schema.projectProp)))
    }

    static func parseDate(_ s: String) -> (Date?, Bool) {
        if s.count <= 10 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd"
            return (f.date(from: s), false)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return (d, true) }
        iso.formatOptions = [.withInternetDateTime]
        return (iso.date(from: s), true)
    }

    /// ID базы из ссылки (или сам ID): 32 hex-символа, в формате UUID.
    static func extractID(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        let compact = s.replacingOccurrences(of: "-", with: "")
        var best: String?
        var run = ""
        for ch in compact {
            if ch.isHexDigit {
                run.append(ch)
            } else {
                if run.count >= 32 { best = String(run.suffix(32)) }
                run = ""
            }
        }
        if run.count >= 32 { best = String(run.suffix(32)) }
        guard let hex = best?.lowercased() else { return nil }
        let c = Array(hex)
        return String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-" + String(c[16..<20]) + "-" + String(c[20..<32])
    }

    // MARK: Запросы

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String,
                         version: String = "2022-06-28") async throws -> [String: Any] {
        guard let url = URL(string: "https://api.notion.com/v1/" + path) else { throw NotionError.message("Неверный адрес") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (json["message"] as? String) ?? "HTTP \(code)"
            throw NotionError.message(NotionService.humanize(code: code, message: message))
        }
        return json
    }

    private static func humanize(code: Int, message: String) -> String {
        switch code {
        case 401: return "Токен Notion не подходит — проверьте его в настройках"
        case 403: return "Нет доступа к базе — добавьте интеграцию в Connections базы"
        case 404: return "База не найдена — проверьте ссылку и что интеграция добавлена в Connections базы"
        case 429: return "Notion просит подождать — слишком много запросов"
        default: return "Notion: \(message)"
        }
    }
}
