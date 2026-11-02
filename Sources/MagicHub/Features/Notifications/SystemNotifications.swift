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

    private let queue = DispatchQueue(label: "app.magichub.system-notifications", qos: .utility)
    private var db: OpaquePointer?
    private var lastRecID: Int64 = -1
    private var timer: DispatchSourceTimer?
    /// Слежение за журналом базы (-wal): macOS сама сообщает о новой записи — без задержки опроса.
    private var walSource: DispatchSourceFileSystemObject?
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
        guard on else {
            queue.async { [weak self] in self?.closeDB() }
            status = .off
            return
        }
        // Основной путь — событие записи в журнал базы; опрос — запасной (если событие не пришло).
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval: Double = lite ? 5 : 3
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(lite ? 1000 : 500))
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
        guard let url = Self.databaseURL else { setStatus(.notFound); return }
        if db == nil {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                setStatus(.noAccess)
                return
            }
            sqlite3_busy_timeout(handle, 250)
            db = handle
        }
        watchJournal(url)
        // Первый запуск: старые уведомления не показываем, начинаем с самой свежей записи.
        if lastRecID < 0 {
            guard let maxID = queryMaxID() else { return }
            lastRecID = maxID
            setStatus(.working)
            return
        }
        readNew()
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

    /// Есть ли в базе поле presented (показан ли баннер). nil — ещё не проверяли.
    private var hasPresentedColumn: Bool?

    private func readNew() {
        let withPresented = hasPresentedColumn ?? true
        let sql = "SELECT r.rec_id, a.identifier, r.data" + (withPresented ? ", r.presented" : "")
            + " FROM record r JOIN app a ON a.app_id = r.app_id WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 20"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if withPresented && hasPresentedColumn == nil {
                hasPresentedColumn = false   // старая схема без presented — читать без него
                readNew()
            } else {
                failQuery()
            }
            return
        }
        hasPresentedColumn = withPresented
        sqlite3_bind_int64(stmt, 1, lastRecID)
        var rows: [(id: Int64, app: String, data: Data, presented: Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let app = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            var data = Data()
            if let blob = sqlite3_column_blob(stmt, 2) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            let presented = withPresented ? sqlite3_column_int(stmt, 3) != 0 : true
            rows.append((id, app, data, presented))
        }
        if case .working = status {} else { setStatus(.working) }
        // Фокус (на Mac или с iPhone): уведомления, которые он заглушил, в хаб не попадают —
        // показываем только те, что macOS пропустила сквозь фокус.
        let focus = !rows.isEmpty && FocusState.isActive()
        for row in rows {
            lastRecID = max(lastRecID, row.id)
            if focus && !row.presented { continue }
            present(row.app, row.data)
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
        hasPresentedColumn = nil
        walSource?.cancel()
        walSource = nil
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// usernoted дописывает новое уведомление в db-wal — читаем сразу по событию записи.
    private func watchJournal(_ dbURL: URL) {
        guard walSource == nil else { return }
        let fd = open(dbURL.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // Журнал пересоздан — следить за новым файлом со следующего опроса.
                self.walSource?.cancel()
                self.walSource = nil
            }
            self.poll()
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
        l.append("фокус сейчас: " + (FocusState.isActive() ? "включён" : "выключен") + " (" + FocusState.summary() + ")")
        if sqlite3_prepare_v2(handle, "SELECT r.rec_id, a.identifier, r.data, r.presented, r.style FROM record r JOIN app a ON a.app_id = r.app_id ORDER BY r.rec_id DESC LIMIT 5", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let shown = "presented=\(sqlite3_column_int(stmt, 3)) style=\(sqlite3_column_int(stmt, 4))"
                let app = (sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "?") + " " + shown
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

    private func present(_ identifier: String, _ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let req = plist["req"] as? [String: Any] ?? [:]
        let bundle = (plist["app"] as? String) ?? identifier
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
        let note = NotchNotification(title: main, subtitle: second, kind: .message, icon: "bell.fill", appIcon: icon, onTap: {
            if let appURL {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        })
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
        DispatchQueue.main.async {
            AppModel.shared.post(note)
            // В фокусе «Не беспокоить» macOS молчит — звук даёт хаб.
            if Prefs.shared.notifSound { NSSound(named: NSSound.Name("Glass"))?.play() }
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
enum FocusState {
    private static let lock = NSLock()
    private static var cache: (date: Date, active: Bool, summary: String)?

    static func isActive() -> Bool { read().active }
    static func summary() -> String { read().summary }

    private static func read() -> (active: Bool, summary: String) {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.date) < 2 { return (c.active, c.summary) }
        let url = AppPaths.home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        var active = false
        var summary = "файл фокуса не читается"
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let stores = root["data"] as? [[String: Any]] ?? []
            var modes: [String] = []
            for store in stores {
                let assertions = store["storeAssertionRecords"] as? [[String: Any]] ?? []
                // Завершённые фокусы перечислены в storeInvalidationRecords.
                let invalidated = Set((store["storeInvalidationRecords"] as? [[String: Any]] ?? []).compactMap { rec -> String? in
                    (rec["invalidationAssertion"] as? [String: Any])?["assertionUUID"] as? String ?? rec["assertionUUID"] as? String
                })
                for a in assertions where !invalidated.contains(a["assertionUUID"] as? String ?? "") {
                    active = true
                    let details = a["assertionDetails"] as? [String: Any]
                    modes.append((details?["assertionDetailsModeIdentifier"] as? String ?? "?")
                        .replacingOccurrences(of: "com.apple.donotdisturb.mode.", with: "")
                        .replacingOccurrences(of: "com.apple.focus.", with: ""))
                }
            }
            summary = modes.isEmpty ? "активных нет" : "активные: " + modes.joined(separator: ", ")
        }
        cache = (Date(), active, summary)
        return (active, summary)
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
                    SettingsRow("Фокус уважается",
                                subtitle: "Пока включён фокус (на Mac или с iPhone), в чёлку приходят только уведомления, которые он пропустил") {
                        Image(systemName: "moon.fill").foregroundStyle(MH.t2)
                    }
                    SettingsToggleRow("Звук уведомления",
                                      subtitle: "Если у приложения баннер выключен и macOS молчит — звук сыграет хаб",
                                      isOn: $prefs.notifSound)
                    if !monitor.recentApps.isEmpty {
                        SettingsRow("Чтобы баннеры macOS не дублировали чёлку",
                                    subtitle: "Отключите баннер у приложения (стиль «Нет») — его уведомления останутся в чёлке") { EmptyView() }
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
}
