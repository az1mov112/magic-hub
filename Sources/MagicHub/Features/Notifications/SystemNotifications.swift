import AppKit
import SwiftUI
import Combine
import SQLite3
import ApplicationServices

/// Уведомления macOS → в чёлку со значком приложения.
/// Перехватить чужие уведомления macOS не даёт, но каждое из них записывается в базу Центра
/// уведомлений. Magic Hub читает только новые записи этой базы (нужен «Полный доступ к диску»)
/// и ничего никуда не отправляет.
final class SystemNotificationsMonitor: ObservableObject {
    static let shared = SystemNotificationsMonitor()

    enum Status: Equatable { case off, noAccess, notFound, working, failed(String) }
    @Published private(set) var status: Status = .off

    /// Приложения, которые недавно присылали уведомления, — для кнопок «Отключить баннер».
    struct RecentApp: Identifiable {
        let bundle: String
        let name: String
        let icon: NSImage?
        var id: String { bundle }
    }
    @Published private(set) var recentApps: [RecentApp] = []

    /// Скорость последнего уведомления — для строки в настройках.
    struct Speed: Equatable {
        /// От доставки в macOS до появления в чёлке, с.
        let total: Double
        /// Сколько из этого macOS не записывала уведомление в базу (нижняя оценка), с.
        let system: Double
    }
    @Published private(set) var lastSpeed: Speed?

    private let queue = DispatchQueue(label: "app.magichub.system-notifications", qos: .userInitiated)
    private var db: OpaquePointer?
    private var dbURL: URL?
    private var lastRecID: Int64 = -1
    /// Время запуска слежения (секунды от 2001 года): старые уведомления не показываем.
    private var startRef: Double = 0
    /// Уже известные записи (uuid → когда). Номер записи macOS может выдать повторно, если удалила
    /// последнюю (сообщение прочитали на телефоне), поэтому новые записи узнаём ещё и по uuid.
    private var seen: [String: Date] = [:]
    private var timer: DispatchSourceTimer?
    /// Без этого macOS усыпляет фоновое приложение (App Nap) и придерживает его таймеры на секунды.
    private var activity: NSObjectProtocol?
    private var napDisabled = false   // то же, но для чтения на queue
    /// Слежение за журналом базы (-wal): macOS сама сообщает о новой записи — без задержки опроса.
    private var walSource: DispatchSourceFileSystemObject?
    private var followUpScheduled = false

    // Замеры для диагностики.
    private struct Timing {
        let id = UUID()
        let app: String
        let delivered: Date
        /// Предыдущая проверка базы, которая этой записи ещё не нашла.
        let prevPoll: Date?
        let read: Date
        var shown: Date?
    }
    private var timings: [Timing] = []
    private var pollTimes: [Date] = []
    private var pollDurations: [Double] = []
    private var walEvents: [Date] = []
    private var lastPoll: Date?
    private var cancellables = Set<AnyCancellable>()
    private var recent: [String: Date] = [:]
    private var icons: [String: NSImage] = [:]
    private let ownBundle = Bundle.main.bundleIdentifier ?? "app.magichub.MagicHub"

    func start() {
        let p = Prefs.shared
        p.$systemNotifications.combineLatest(p.$lite)
            .receive(on: RunLoop.main)
            .sink { [weak self] on, lite in self?.schedule(on: on, lite: lite) }
            .store(in: &cancellables)
    }

    /// Проверить снова (после выдачи «Полного доступа к диску»).
    func retry() {
        queue.async { [weak self] in
            self?.closeDB()
            self?.lastRecID = -1
            self?.poll()
        }
    }

    private func schedule(on: Bool, lite: Bool) {
        timer?.cancel()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard on else {
            queue.async { [weak self] in
                self?.closeDB()
                self?.lastRecID = -1   // после включения — только новые, без накопившихся
                self?.napDisabled = false
            }
            status = .off
            return
        }
        // Не даём macOS «усыплять» хаб: иначе проверка 4 раза в секунду на деле идёт раз в несколько секунд.
        // На сон Mac и экрана это не влияет.
        activity = ProcessInfo.processInfo.beginActivity(
            options: lite ? [.userInitiatedAllowingIdleSystemSleep] : [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Уведомления Mac в чёлке")
        queue.async { [weak self] in self?.napDisabled = true }
        // Основной путь — событие записи в журнал базы; опрос — запасной (если событие не пришло).
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Проверка — один короткий запрос к открытой базе, поэтому почти непрерывно: 4 раза в секунду.
        let interval: Double = lite ? 1 : 0.25
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(lite ? 200 : 40))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: База Центра уведомлений (только на queue)

    /// macOS 15+: группа usernoted; раньше — папка пользователя в /var/folders.
    static var databaseURL: URL? {
        let fm = FileManager.default
        var candidates = [AppPaths.home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            candidates.append(URL(fileURLWithPath: String(cString: buf)).appendingPathComponent("com.apple.notificationcenter/db2/db"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func poll() {
        let started = Date()
        defer {
            lastPoll = started
            pollTimes.append(started)
            if pollTimes.count > 240 { pollTimes.removeFirst(pollTimes.count - 240) }
            pollDurations.append(Date().timeIntervalSince(started) * 1000)
            if pollDurations.count > 60 { pollDurations.removeFirst(pollDurations.count - 60) }
        }
        guard let url = dbURL ?? Self.databaseURL else { setStatus(.notFound); return }
        if db == nil {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                setStatus(.noAccess)
                return
            }
            sqlite3_busy_timeout(handle, 250)
            db = handle
            dbURL = url
        }
        watchJournal(url)
        // Первый запуск: старые уведомления не показываем, начинаем с самой свежей записи.
        if lastRecID < 0 {
            guard let maxID = queryMaxID() else { return }
            lastRecID = maxID
            startRef = Date().timeIntervalSinceReferenceDate
            // Всё, что уже лежит в базе, — старое: даже если macOS обновит запись, второй раз не показываем.
            seen = [:]
            for key in queryAllKeys() { seen[key] = Date() }
            setStatus(.working)
            return
        }
        readNew(prevPoll: lastPoll)
    }

    private func queryMaxID() -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            failQuery()
            return nil
        }
        return sqlite3_column_int64(stmt, 0)
    }

    private func queryAllKeys() -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT rec_id, hex(uuid) FROM record", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            keys.append(uuid.isEmpty ? "#\(sqlite3_column_int64(stmt, 0))" : uuid)
        }
        return keys
    }

    /// Новые записи: с номером больше последнего прочитанного или доставленные за последние полминуты
    /// (номер мог достаться повторно), кроме уже показанных.
    private func readNew(prevPoll: Date?) {
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date, hex(r.uuid) FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? OR r.delivered_date > ? ORDER BY r.rec_id LIMIT 40
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            failQuery()
            return
        }
        let now = Date()
        sqlite3_bind_int64(stmt, 1, lastRecID)
        sqlite3_bind_double(stmt, 2, max(startRef, now.timeIntervalSinceReferenceDate - 30))
        var rows: [(id: Int64, app: String, data: Data, delivered: Double, key: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let uuid = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let key = uuid.isEmpty ? "#\(id)" : uuid
            lastRecID = max(lastRecID, id)
            guard seen[key] == nil else { continue }
            seen[key] = now
            let app = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            var data = Data()
            if let blob = sqlite3_column_blob(stmt, 2) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            rows.append((id, app, data, sqlite3_column_double(stmt, 3), key))
        }
        if seen.count > 3000 { seen = seen.filter { now.timeIntervalSince($0.value) < 86400 } }
        if case .working = status {} else { setStatus(.working) }
        for row in rows {
            // delivered_date — секунды от 2001 года (когда macOS приняла уведомление).
            var timingID: UUID?
            if row.delivered > 0 {
                let delivered = Date(timeIntervalSinceReferenceDate: row.delivered)
                let lag = now.timeIntervalSince(delivered)
                if lag >= 0 && lag < 600 {
                    let t = Timing(app: row.app, delivered: delivered, prevPoll: prevPoll, read: now)
                    timings.append(t)
                    if timings.count > 6 { timings.removeFirst() }
                    timingID = t.id
                }
            }
            present(row.app, row.data, timingID: timingID)
        }
    }

    /// Уведомление появилось в чёлке — записать, сколько оно шло.
    private func markShown(_ id: UUID) {
        queue.async { [weak self] in
            guard let self, let i = self.timings.firstIndex(where: { $0.id == id }) else { return }
            let now = Date()
            self.timings[i].shown = now
            let t = self.timings[i]
            let system = max(0, (t.prevPoll ?? t.delivered).timeIntervalSince(t.delivered))
            let speed = Speed(total: now.timeIntervalSince(t.delivered), system: system)
            DispatchQueue.main.async { self.lastSpeed = speed }
        }
    }

    private func failQuery() {
        let message = String(cString: sqlite3_errmsg(db))
        closeDB()
        // Без «Полного доступа к диску» база открывается, но не читается.
        if message.contains("authorization") || message.contains("unable to open") || message.contains("not authorized") {
            setStatus(.noAccess)
        } else {
            setStatus(.failed(message))
        }
    }

    private func closeDB() {
        walSource?.cancel()
        walSource = nil
        if let db { sqlite3_close(db) }
        db = nil
        dbURL = nil
    }

    /// usernoted дописывает новое уведомление в db-wal — читаем сразу по событию записи.
    private func watchJournal(_ dbURL: URL) {
        guard walSource == nil else { return }
        let fd = open(dbURL.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.walEvents.append(Date())
            if self.walEvents.count > 64 { self.walEvents.removeFirst(self.walEvents.count - 64) }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // Журнал пересоздан — следить за новым файлом со следующего опроса.
                self.walSource?.cancel()
                self.walSource = nil
            }
            self.poll()
            // Запись могла быть ещё не завершена — перечитать вдогонку.
            if !self.followUpScheduled {
                self.followUpScheduled = true
                self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
                self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.followUpScheduled = false
                    self?.poll()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        walSource = src
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { if self.status != s { self.status = s } }
    }

    // MARK: Диагностика

    /// Отчёт без текста уведомлений: где база, есть ли доступ, какие поля в записях. Вызывать не из queue.
    func diagnostics() -> String {
        queue.sync { diagnosticsText() }
    }

    private func diagnosticsText() -> String {
        var l = ["[Уведомления Mac]"]
        l.append("включено: " + (Prefs.shared.systemNotifications ? "да" : "нет") + ", статус: \(status)")
        let home = AppPaths.home.path
        let groupPath = AppPaths.home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
        l.append("база usernoted: " + (FileManager.default.fileExists(atPath: groupPath) ? "есть" : "нет")
                 + ", читается: " + (FileManager.default.isReadableFile(atPath: groupPath) ? "да" : "нет"))
        guard let url = Self.databaseURL else {
            l.append("база не найдена")
            return l.joined(separator: "\n")
        }
        l.append("путь: " + url.path.replacingOccurrences(of: home, with: "~"))
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            l.append("не открывается: " + String(cString: sqlite3_errmsg(handle)))
            sqlite3_close(handle)
            return l.joined(separator: "\n")
        }
        defer { sqlite3_close(handle) }
        func rows(_ sql: String, _ cols: Int32) -> [[String]]? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                l.append("запрос «\(sql.prefix(40))…»: " + String(cString: sqlite3_errmsg(handle)))
                return nil
            }
            var out: [[String]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((0..<cols).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" })
            }
            return out
        }
        if let tables = rows("SELECT name FROM sqlite_master WHERE type='table'", 1) {
            l.append("таблицы: " + tables.map { $0[0] }.joined(separator: ", "))
        }
        if let cols = rows("PRAGMA table_info(record)", 2) {
            l.append("поля record: " + cols.map { $0[1] }.joined(separator: ", "))
        }
        if let stat = rows("SELECT COUNT(*), MAX(rec_id) FROM record", 2), let s = stat.first {
            l.append("записей: \(s[0]), последняя: \(s[1]), Magic Hub читает после: \(lastRecID)")
        }
        // Три последние записи — только приложение и названия полей.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        l += speedDetails()
        l.append("фокус сейчас: " + (MacFocus.isActive() ? "включён" : "выключен") + " (" + MacFocus.summary() + ")")
        if MacFocus.isActive() {
            l.append("настройки фокуса:")
            l += MacFocus.rulesDetails()
        }
        if sqlite3_prepare_v2(handle, "SELECT r.rec_id, a.identifier, r.data, r.presented, r.style, r.request_date, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id ORDER BY r.rec_id DESC LIMIT 5", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let requested = sqlite3_column_double(stmt, 5), delivered = sqlite3_column_double(stmt, 6)
                let timing = requested > 0 && delivered > 0
                    ? String(format: " запрос→доставка %.1f с, доставлено %.0f с назад", delivered - requested,
                             Date().timeIntervalSinceReferenceDate - delivered)
                    : ""
                let shown = "presented=\(sqlite3_column_int(stmt, 3)) style=\(sqlite3_column_int(stmt, 4))" + timing
                let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "?"
                let verdict: String
                switch MacFocus.allows(bundle) {
                case .some(true): verdict = "показать"
                case .some(false): verdict = "заглушено фокусом"
                case .none: verdict = "фокус не разобран — показать"
                }
                let app = bundle + " " + shown + " → " + verdict
                var keys = "?"
                if let blob = sqlite3_column_blob(stmt, 2) {
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        let req = (plist["req"] as? [String: Any]).map { " req: " + $0.keys.sorted().joined(separator: ",") } ?? ""
                        keys = plist.keys.sorted().joined(separator: ",") + req
                    } else {
                        keys = "не plist (\(data.count) байт)"
                    }
                }
                l.append("  #\(id) \(app): \(keys)")
            }
        } else {
            l.append("последние записи: " + String(cString: sqlite3_errmsg(handle)))
        }
        return l.joined(separator: "\n")
    }

    /// Где теряется время: опрос базы, запись macOS в базу, показ в чёлке.
    private func speedDetails() -> [String] {
        let now = Date()
        func f(_ x: Double) -> String { String(format: "%+.1f", x) }
        let polls = pollTimes.filter { now.timeIntervalSince($0) < 10 }.count
        let avg = pollDurations.isEmpty ? 0 : pollDurations.reduce(0, +) / Double(pollDurations.count)
        let wal = walEvents.filter { now.timeIntervalSince($0) < 10 }.count
        var l = ["проверок базы за 10 с: \(polls) (норма ~\(Prefs.shared.lite ? 10 : 40)), одна проверка: в среднем "
                 + String(format: "%.1f", avg) + " мс, макс " + String(format: "%.1f", pollDurations.max() ?? 0) + " мс"]
        l.append("журнал базы: " + (walSource == nil ? "не отслеживается" : "отслеживается") + ", изменений за 10 с: \(wal)"
                 + ", App Nap: " + (napDisabled ? "отключён" : "не отключён"))
        if timings.isEmpty {
            l.append("скорость: уведомлений с запуска ещё не было")
        } else {
            l.append("последние уведомления (секунды от момента, когда macOS их приняла):")
            for t in timings.suffix(5) {
                let readAt = t.read.timeIntervalSince(t.delivered)
                let before = t.prevPoll.map { f($0.timeIntervalSince(t.delivered)) } ?? "?"
                let shown = t.shown.map { "показано " + f($0.timeIntervalSince(t.delivered)) } ?? "не показано (сменилось новым или отфильтровано)"
                let journal = walEvents.map { $0.timeIntervalSince(t.delivered) }.filter { $0 > -2 && $0 <= readAt + 0.5 }
                l.append("  \(t.app): в базе не было на \(before), нашлось на \(f(readAt)), \(shown); журнал менялся: "
                         + (journal.isEmpty ? "—" : journal.prefix(8).map(f).joined(separator: ", ")))
            }
        }
        return l
    }

    // MARK: Системные баннеры (экспериментально)

    /// Закрыть баннеры macOS через «Универсальный доступ»: у баннера есть действие «Закрыть».
    /// Открытую панель Центра уведомлений (высокое окно) не трогаем.
    static func closeSystemBanners() {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            if let size = WindowLayoutManager.size(of: w), size.height > 420 { continue }
            closeIn(w, depth: 0)
        }
    }

    private static func closeIn(_ el: AXUIElement, depth: Int) {
        guard depth < 10 else { return }
        var names: CFArray?
        if AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String],
           let close = list.first(where: { n in n.contains("Close") || n.contains("Закрыть") }) {
            AXUIElementPerformAction(el, close as CFString)
            return
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return }
        for c in children { closeIn(c, depth: depth + 1) }
    }

    // MARK: Показ

    private func present(_ identifier: String, _ data: Data, timingID: UUID?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let req = plist["req"] as? [String: Any] ?? [:]
        let bundle = (plist["app"] as? String) ?? identifier
        // Фокус (на Mac или с iPhone): приложения, которые он глушит, в хаб не попадают —
        // кроме неотложных уведомлений (уровень «time sensitive» и выше), как и у самой macOS.
        if MacFocus.allows(bundle) == false {
            let level = (plist["intl"] as? NSNumber)?.intValue ?? 1
            if level < 2 { return }
        }
        guard bundle.caseInsensitiveCompare(ownBundle) != .orderedSame else { return }
        func field(_ keys: String...) -> String {
            for k in keys {
                if let v = (req[k] ?? plist[k]) as? String { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return ""
        }
        let title = field("titl", "title")
        let sub = field("subt", "subtitle")
        let body = field("body", "message")
        let main = !title.isEmpty ? title : (!sub.isEmpty ? sub : body)
        guard !main.isEmpty else { return }
        let second = [sub, body].filter { !$0.isEmpty && $0 != main }.joined(separator: " · ")
            .replacingOccurrences(of: "\n", with: " ")

        // Одно и то же уведомление иногда приходит дважды подряд (обновление записи).
        let key = bundle + "|" + main + "|" + second
        let now = Date()
        if let seen = recent[key], now.timeIntervalSince(seen) < 3 { return }
        recent[key] = now
        if recent.count > 200 { recent = recent.filter { now.timeIntervalSince($0.value) < 60 } }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        let icon: NSImage?
        if let cached = icons[bundle] {
            icon = cached
        } else {
            icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            if let icon { icons[bundle] = icon }
        }
        var note = NotchNotification(title: main, subtitle: second, kind: .message, icon: "bell.fill", appIcon: icon, onTap: {
            if let appURL {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        })
        note.source = bundle
        if let timingID { note.onShown = { [weak self] in self?.markShown(timingID) } }
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
        DispatchQueue.main.async {
            AppModel.shared.post(note)   // без звука: родной звук приложения играет сама macOS
            var apps = self.recentApps.filter { $0.bundle != bundle }
            apps.insert(RecentApp(bundle: bundle, name: name, icon: icon), at: 0)
            self.recentApps = Array(apps.prefix(8))
        }
        if Prefs.shared.hideSystemBanners {
            // Баннер macOS появляется чуть позже записи в базу — закрыть его, как только он есть.
            for delay in [0.15, 0.5, 1.2] {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { Self.closeSystemBanners() }
            }
        }
    }
}

/// Включён ли фокус — на этом Mac или пришедший с iPhone («Общий доступ между устройствами»).
/// donotdisturbd записывает активные фокусы в ~/Library/DoNotDisturb/DB/Assertions.json
/// (читается с «Полным доступом к диску»).
enum MacFocus {
    /// Что фокус делает с приложениями: список разрешённых или заглушённых (bundle id в нижнем регистре).
    struct Rules {
        var allowed: Set<String>?
        var silenced: Set<String>?
        var details: [String]
    }

    private static let lock = NSLock()
    private static var cache: (date: Date, modes: [String], summary: String, rules: Rules?)?
    private static let dir = AppPaths.home.appendingPathComponent("Library/DoNotDisturb/DB")

    static func isActive() -> Bool { !read().modes.isEmpty }
    static func summary() -> String { read().summary }
    static func rulesDetails() -> [String] { read().rules?.details ?? ["настройки фокуса не прочитаны"] }

    /// Строка для настроек: что сейчас делает фокус с уведомлениями в чёлке.
    static func settingsSummary() -> String {
        let s = read()
        guard !s.modes.isEmpty else {
            return "Пока включён фокус (на Mac или с iPhone), в чёлку приходят только уведомления, которые он пропускает"
        }
        func names(_ set: Set<String>) -> String {
            let list = set.sorted().map { b -> String in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return b }
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            return list.prefix(6).joined(separator: ", ") + (list.count > 6 ? " и ещё \(list.count - 6)" : "")
        }
        if let allowed = s.rules?.allowed { return "Сейчас включён фокус. В чёлку проходят: " + names(allowed) + " и неотложные" }
        if let silenced = s.rules?.silenced { return "Сейчас включён фокус. Не проходят: " + names(silenced) }
        return "Сейчас включён фокус, но его список приложений прочитать не удалось — показываются все уведомления"
    }

    /// Пропускает ли включённый фокус уведомления приложения. nil — неизвестно (настройки фокуса не разобраны):
    /// тогда уведомление показываем, чтобы не терять его.
    static func allows(_ bundle: String) -> Bool? {
        let s = read()
        guard !s.modes.isEmpty else { return true }
        guard let r = s.rules else { return nil }
        let b = bundle.lowercased()
        if let allowed = r.allowed { return allowed.contains(b) }
        if let silenced = r.silenced { return !silenced.contains(b) }
        return nil
    }

    private static func read() -> (modes: [String], summary: String, rules: Rules?) {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.date) < 2 { return (c.modes, c.summary, c.rules) }
        var modes: [String] = []
        var summary = "файл фокуса не читается"
        if let data = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for store in root["data"] as? [[String: Any]] ?? [] {
                let assertions = store["storeAssertionRecords"] as? [[String: Any]] ?? []
                // Завершённые фокусы перечислены в storeInvalidationRecords.
                let invalidated = Set((store["storeInvalidationRecords"] as? [[String: Any]] ?? []).compactMap { rec -> String? in
                    (rec["invalidationAssertion"] as? [String: Any])?["assertionUUID"] as? String ?? rec["assertionUUID"] as? String
                })
                for a in assertions where !invalidated.contains(a["assertionUUID"] as? String ?? "") {
                    if let id = (a["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String {
                        modes.append(id)
                    }
                }
            }
            summary = modes.isEmpty ? "активных нет" : "активные: " + modes.map(short).joined(separator: ", ")
        }
        let rules = modes.first.flatMap(rules(for:))
        cache = (Date(), modes, summary, rules)
        return (modes, summary, rules)
    }

    private static func short(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.donotdisturb.mode.", with: "").replacingOccurrences(of: "com.apple.focus.", with: "")
    }

    /// Какие приложения фокус пропускает или глушит. Формат Apple не документирован и меняется
    /// от версии к версии, поэтому ищем по смыслу во всех файлах настроек фокуса: идентификаторы
    /// приложений (и в значениях, и в ключах) внутри части, относящейся к включённому фокусу.
    private static func rules(for modeID: String) -> Rules? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var inMode: [(path: String, bundle: String)] = []
        var elsewhere: [String: (example: String, count: Int)] = [:]
        var config: [String: Any]?
        var fileNotes: [String] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" && url.lastPathComponent != "Assertions.json" {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url), data.count < 8_000_000,
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                fileNotes.append(name + " (не читается)")
                continue
            }
            var mine = 0, other = 0
            scan(root, path: [], inMode: false, modeID: modeID) { path, bundle, isMode in
                let p = name + " › " + path.joined(separator: ".").replacingOccurrences(of: modeID, with: "<фокус>")
                if isMode {
                    inMode.append((p, bundle))
                    mine += 1
                } else {
                    let e = elsewhere[p]
                    elsewhere[p] = (e?.example ?? bundle, (e?.count ?? 0) + 1)
                    other += 1
                }
            }
            if config == nil, let m = find(modeID, in: root, parent: nil) as? [String: Any] {
                config = m["configuration"] as? [String: Any]
            }
            fileNotes.append("\(name) \(data.count / 1024) КБ: приложений в этом фокусе \(mine), вне его \(other)")
        }

        var allowed = Set<String>(), silenced = Set<String>()
        for f in inMode {
            let p = f.path.lowercased()
            // Приложения-«включатели» фокуса и фильтры фокуса — не про уведомления.
            if p.contains("trigger") || p.contains("filter") { continue }
            if p.contains("deny") || p.contains("silenc") || p.contains("block") || p.contains("suppress") || p.contains("exclu") {
                silenced.insert(f.bundle.lowercased())
            } else {
                allowed.insert(f.bundle.lowercased())
            }
        }

        // Для диагностики: где лежат приложения и простые настройки фокуса (без людей и имён).
        var details = ["  файлы: " + (fileNotes.isEmpty ? "нет" : fileNotes.joined(separator: "; "))]
        if let config {
            let scalars = config.compactMap { k, v -> String? in (v is NSNumber) ? "\(k)=\(v)" : nil }.sorted()
            details.append("  настройки: " + scalars.joined(separator: ", "))
        }
        for f in inMode.prefix(12) { details.append("  " + f.path + ": " + f.bundle) }
        if inMode.isEmpty {
            details.append("  приложений в настройках фокуса не найдено")
            for (path, e) in elsewhere.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
                details.append("  вне фокуса — " + path + ": \(e.example) (\(e.count))")
            }
        }
        if !allowed.isEmpty { details.append("  пропускает: " + allowed.sorted().joined(separator: ", ")) }
        if !silenced.isEmpty { details.append("  глушит: " + silenced.sorted().joined(separator: ", ")) }
        return Rules(allowed: allowed.isEmpty ? nil : allowed, silenced: silenced.isEmpty ? nil : silenced, details: details)
    }

    /// Обход JSON: каждый идентификатор приложения с путём и признаком «внутри включённого фокуса».
    /// Внутри фокуса — словарь, где modeIdentifier (или вложенный mode.modeIdentifier) равен фокусу,
    /// любое его значение равно фокусу, либо ключ словаря — сам фокус.
    private static func scan(_ node: Any, path: [String], inMode: Bool, modeID: String,
                             _ emit: (_ path: [String], _ bundle: String, _ inMode: Bool) -> Void) {
        if let d = node as? [String: Any] {
            let here = inMode || d.values.contains { v in
                (v as? String) == modeID || ((v as? [String: Any])?["modeIdentifier"] as? String) == modeID
            }
            for (k, v) in d {
                let child = here || k == modeID
                if isBundleID(k, modeID) { emit(path + [k], k, child) }
                if let str = v as? String, isBundleID(str, modeID) { emit(path + [k], str, child) }
                scan(v, path: path + [k], inMode: child, modeID: modeID, emit)
            }
        } else if let a = node as? [Any] {
            for v in a {
                if let str = v as? String, isBundleID(str, modeID) { emit(path, str, inMode) }
                scan(v, path: path, inMode: inMode, modeID: modeID, emit)
            }
        }
    }

    /// Похоже на идентификатор приложения: ru.keepcoder.Telegram, net.whatsapp.WhatsApp.
    private static func isBundleID(_ s: String, _ modeID: String) -> Bool {
        guard s.count >= 5, s.count <= 120, s != modeID,
              !s.hasPrefix("com.apple.donotdisturb"), !s.hasPrefix("com.apple.focus") else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, (2...6).contains(first.count),
              first.allSatisfy({ $0.isLetter && $0.isLowercase && $0.isASCII }) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Узел настроек фокуса: словарь, внутри которого mode.modeIdentifier == modeID.
    private static func find(_ modeID: String, in node: Any, parent: Any?) -> Any? {
        if let d = node as? [String: Any] {
            if (d["modeIdentifier"] as? String) == modeID { return parent ?? d }
            for v in d.values { if let r = find(modeID, in: v, parent: d) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = find(modeID, in: v, parent: parent) { return r } }
        }
        return nil
    }
}

/// Настройки: уведомления Mac в чёлке.
struct SystemNotificationsSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var monitor = SystemNotificationsMonitor.shared

    var body: some View {
        SettingsSection("Уведомления Mac") {
            SettingsToggleRow("Показывать уведомления Mac в чёлке",
                              subtitle: "Сообщения, письма, напоминания — со значком приложения. Клик открывает приложение",
                              isOn: $prefs.systemNotifications)
            SettingsSegmentRow("Сколько висит уведомление",
                               subtitle: "Наведение и раскрытие хаба его не убирают — только время",
                               options: [(4.0, "4 с"), (6.0, "6 с"), (8.0, "8 с"), (12.0, "12 с")],
                               selection: $prefs.notifSeconds)
            if prefs.systemNotifications {
                switch monitor.status {
                case .noAccess:
                    SettingsButtonRow("Нужен «Полный доступ к диску»",
                                      subtitle: "Включите Magic Hub в списке, затем нажмите «Проверить». Иначе macOS не даёт прочитать уведомления",
                                      buttonTitle: "Открыть") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    SettingsButtonRow("Уже разрешили?", buttonTitle: "Проверить") { monitor.retry() }
                case .notFound:
                    SettingsRow("База уведомлений не найдена", subtitle: "Эта версия macOS хранит уведомления по-другому") { EmptyView() }
                case .failed(let message):
                    SettingsButtonRow("Не удалось прочитать уведомления", subtitle: message, buttonTitle: "Повторить") { monitor.retry() }
                case .working:
                    SettingsRow("Работает", subtitle: "Уведомления приходят в чёлку") {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(MH.green)
                    }
                    if let speed = monitor.lastSpeed {
                        SettingsRow("Скорость", subtitle: speedText(speed)) {
                            Text(seconds(speed.total)).font(.system(size: 12, weight: .semibold)).foregroundStyle(MH.t2).monospacedDigit()
                        }
                    }
                    SettingsRow("Фокус уважается", subtitle: MacFocus.settingsSummary()) {
                        Image(systemName: "moon.fill").foregroundStyle(MH.t2)
                    }
                    if !monitor.recentApps.isEmpty {
                        SettingsRow("Чтобы баннеры macOS не дублировали чёлку",
                                    subtitle: "Отключите баннер у приложения (стиль «Нет») — его уведомления останутся в чёлке, а родной звук сыграет сама macOS, если «Звук для уведомлений» включён") { EmptyView() }
                        ForEach(monitor.recentApps) { app in
                            HStack(spacing: 10) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                }
                                Text(app.name).font(.system(size: 12)).foregroundStyle(MH.t1)
                                Spacer()
                                Button("Отключить баннер") {
                                    let link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + app.bundle
                                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                                }
                                .buttonStyle(MHButtonStyle())
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    SettingsToggleRow("Закрывать системные баннеры (эксперимент)",
                                      subtitle: "Баннер закрывается сразу после появления, но может мелькнуть, и уведомление уходит из Центра уведомлений",
                                      isOn: $prefs.hideSystemBanners)
                case .off:
                    EmptyView()
                }
            }
        }
    }

    private func seconds(_ x: Double) -> String {
        String(format: "%.1f с", x).replacingOccurrences(of: ".", with: ",")
    }

    private func speedText(_ s: SystemNotificationsMonitor.Speed) -> String {
        let base = "Последнее уведомление появилось в чёлке через \(seconds(s.total)) после того, как его приняла macOS"
        guard s.system >= 1 else { return base }
        return base + ". Из них около \(seconds(s.system)) macOS не записывала его в базу — раньше этого хаб его не увидит"
    }
}
