import AppKit
import SwiftUI
import EventKit
import ServiceManagement
import ApplicationServices

/// Все разрешения, которые могут понадобиться Magic Hub, — с проверкой и запросом одной кнопкой.
final class PermissionsCenter: ObservableObject {
    enum State: Equatable { case granted, denied, unknown, notNeeded }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        var state: State
        let settingsURL: String?
    }

    static let shared = PermissionsCenter()

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false
    @Published private(set) var progress: String?

    init() { refresh() }

    func refresh() {
        var list: [Item] = []

        list.append(Item(id: "accessibility", title: "Универсальный доступ", detail: "Свои индикаторы громкости и яркости в чёлке вместо системных",
                         state: AXIsProcessTrusted() ? .granted : .unknown,
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))

        let cal = EKEventStore.authorizationStatus(for: .event)
        list.append(Item(id: "calendar", title: "Календарь", detail: "Встречи во вкладке «Календарь» (режим «Календарь Mac»)",
                         state: cal == .fullAccess ? .granted : (cal == .notDetermined ? .unknown : .denied),
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))

        let folder = ClipboardWatcher.screenshotFolder()
        // Не трогаем защищённую папку (Рабочий стол), пока пользователь сам не нажал «Запросить»:
        // иначе системный запрос выскочит просто при открытии настроек.
        let folderAsked = UserDefaults.standard.bool(forKey: "perm.folderRequested")
        let folderOK = folderAsked && (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        list.append(Item(id: "folder", title: "Папка скриншотов", detail: (folder.path as NSString).abbreviatingWithTildeInPath + " — чтобы снимки попадали на полку",
                         state: folderOK ? .granted : .unknown,
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"))

        list.append(Item(id: "paste", title: "Вставка из других приложений", detail: "История буфера и полка снимков. macOS спросит при первом чтении буфера",
                         state: UserDefaults.standard.bool(forKey: "perm.pasteRequested") ? .granted : .unknown,
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"))

        list.append(Item(id: "helper", title: "Помощник администратора", detail: "Работа с закрытой крышкой и вентиляторы. Пароль спрашивается один раз",
                         state: PrivilegedHelper.isInstalled ? .granted : .unknown, settingsURL: nil))

        let login = SMAppService.mainApp.status
        list.append(Item(id: "login", title: "Запуск при входе", detail: "Magic Hub стартует вместе с Mac",
                         state: login == .enabled ? .granted : (login == .requiresApproval ? .denied : .unknown),
                         settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))

        let claude = FileManager.default.fileExists(atPath: AppPaths.home.appendingPathComponent(".claude").path)
        list.append(Item(id: "claude", title: "Claude Code", detail: claude ? "Найден — траты и лимиты читаются из ~/.claude" : "Не найден — вкладка «ИИ-агенты» покажет только Джарвиса, если он есть",
                         state: claude ? .granted : .notNeeded, settingsURL: nil))

        let notion = Keychain.get("notion.token") != nil
        list.append(Item(id: "notion", title: "Notion", detail: notion ? "Подключён" : "Токен вводится в разделе «Календарь» ниже",
                         state: notion ? .granted : .notNeeded, settingsURL: nil))

        DispatchQueue.main.async { self.items = list }
    }

    var missingCount: Int { items.filter { $0.state == .unknown || $0.state == .denied }.count }

    /// Удалить записи Magic Hub во всех разрешениях (в том числе от прошлых сборок) и запросить заново.
    func resetAndRequest() {
        guard !running, let id = Bundle.main.bundleIdentifier else { return }
        for service in ["Accessibility", "Calendar", "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "ListenEvent", "All"] {
            Shell.run("/usr/bin/tccutil", ["reset", service, id])
        }
        UserDefaults.standard.set(false, forKey: "perm.pasteRequested")
        UserDefaults.standard.set(false, forKey: "perm.folderRequested")
        refresh()
        requestAll()
    }

    /// Запросить всё подряд. Системные окна появятся по очереди.
    func requestAll() {
        guard !running else { return }
        running = true
        AppModel.shared.holdOpen(for: 60)
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        step("Календарь…")
        let store = EKEventStore()
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { self.requestFolderAndPaste() }
        }
    }

    private func requestFolderAndPaste() {
        step("Папка скриншотов…")
        _ = try? FileManager.default.contentsOfDirectory(atPath: ClipboardWatcher.screenshotFolder().path)
        UserDefaults.standard.set(true, forKey: "perm.folderRequested")
        step("Буфер обмена…")
        _ = NSPasteboard.general.string(forType: .string)
        UserDefaults.standard.set(true, forKey: "perm.pasteRequested")

        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        if !PrivilegedHelper.isInstalled {
            step("Пароль администратора…")
            NSApp.activate(ignoringOtherApps: true)
            // NSAppleScript (запрос пароля) — только на главном потоке.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                _ = PrivilegedHelper.install()
                self.finish()
            }
        } else {
            finish()
        }
    }

    private func step(_ text: String) {
        progress = text
    }

    private func finish() {
        running = false
        progress = nil
        UserDefaults.standard.set(true, forKey: "perm.onboarded")
        AppModel.shared.holdOpen(for: 2)
        refresh()
        AppModel.shared.flash(missingCount == 0 ? "Все разрешения выданы" : "Готово — проверьте список")
    }

    /// При первом запуске — подсказка в чёлке.
    func onboardIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "perm.onboarded") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AppModel.shared.post(NotchNotification(title: "Выдайте разрешения одной кнопкой",
                                                   subtitle: "Нажмите — откроются настройки Magic Hub",
                                                   kind: .info, icon: "checkmark.shield",
                                                   onTap: { AppModel.shared.open(.settings) }))
        }
    }
}

/// Секция «Разрешения» вверху настроек.
struct PermissionsSettingsSection: View {
    @ObservedObject private var center = PermissionsCenter.shared

    var body: some View {
        SettingsSection("Разрешения") {
            SettingsRow(center.missingCount == 0 ? "Всё выдано" : "Нужно выдать: \(center.missingCount)",
                        subtitle: center.progress ?? "Системные окна появятся по очереди — везде нажимайте «Разрешить»") {
                Button(center.running ? "Запрашиваю…" : "Запросить все") { center.requestAll() }
                    .buttonStyle(MHButtonStyle(kind: center.missingCount == 0 ? .normal : .prominent))
                    .disabled(center.running)
            }
            SettingsRow("Выдал, а здесь не видно?",
                        subtitle: "После смены подписи в системных списках остаются записи старой версии. Кнопка удалит их и запросит разрешения заново") {
                Button("Сбросить и запросить") { center.resetAndRequest() }
                    .buttonStyle(MHButtonStyle())
                    .disabled(center.running)
            }
            ForEach(center.items) { item in
                SettingsRow(item.title, subtitle: item.detail) {
                    HStack(spacing: 8) {
                        if (item.state == .denied || item.state == .unknown), let link = item.settingsURL, let url = URL(string: link) {
                            Button("Открыть") { NSWorkspace.shared.open(url) }
                                .buttonStyle(MHButtonStyle())
                        }
                        Image(systemName: icon(item.state))
                            .foregroundStyle(color(item.state))
                            .font(.system(size: 14))
                    }
                }
            }
        }
        .onAppear { center.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !center.running { center.refresh() }
        }
    }

    private func icon(_ s: PermissionsCenter.State) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "circle.dashed"
        case .notNeeded: return "minus.circle"
        }
    }

    private func color(_ s: PermissionsCenter.State) -> Color {
        switch s {
        case .granted: return MH.green
        case .denied: return MH.red
        case .unknown: return MH.orange
        case .notNeeded: return MH.t3
        }
    }
}
