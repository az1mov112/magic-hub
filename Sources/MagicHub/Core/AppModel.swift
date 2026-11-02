import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case music, shelf, clipboard, snippets, calendar, translate, notes
    case currency, teleprompter, calculator, ai, awake, notifications, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Музыка"
        case .shelf: return "Полка"
        case .clipboard: return "Буфер"
        case .snippets: return "Заготовки"
        case .calendar: return "Календарь"
        case .translate: return "Перевод"
        case .notes: return "Заметки"
        case .currency: return "Валюта"
        case .teleprompter: return "Телесуфлёр"
        case .calculator: return "Калькулятор"
        case .ai: return "ИИ-агенты"
        case .awake: return "Не спать"
        case .notifications: return "Уведомления"
        case .settings: return "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .music: return "music.note"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "pin"
        case .calendar: return "calendar"
        case .translate: return "translate"
        case .notes: return "note.text"
        case .currency: return "dollarsign.circle"
        case .teleprompter: return "text.viewfinder"
        case .calculator: return "plus.forwardslash.minus"
        case .ai: return "sparkles"
        case .awake: return "moon.zzz"
        case .notifications: return "bell"
        case .settings: return "gearshape"
        }
    }

    /// Вкладки левой колонки; остальные — в правой.
    var isLeft: Bool {
        switch self {
        case .music, .shelf, .clipboard, .snippets, .calendar, .translate, .notes: return true
        default: return false
        }
    }
}

/// Уведомление, которое выезжает из чёлки (например, «Джарвис принял задачу»).
struct NotchNotification: Identifiable, Equatable {
    enum Kind { case progress, success, warning, error, info, message }

    let id = UUID()
    var title: String
    var subtitle: String
    var kind: Kind
    /// SF Symbol слева. По умолчанию — значок Джарвиса.
    var icon: String = "sparkles"
    /// Значок приложения слева (уведомления macOS) — вместо SF Symbol.
    var appIcon: NSImage? = nil
    /// Приложение-источник (bundle id) — для истории уведомлений.
    var source: String? = nil
    /// Что сделать по клику на уведомление (по умолчанию — открыть вкладку «ИИ-агенты»).
    var onTap: (() -> Void)? = nil
    /// Вызывается, когда уведомление появилось в чёлке (замер скорости).
    var onShown: (() -> Void)? = nil

    var color: Color {
        switch kind {
        case .progress, .info: return MH.accent
        case .message: return MH.t1
        case .success: return MH.green
        case .warning: return MH.orange
        case .error: return MH.red
        }
    }

    static func == (a: NotchNotification, b: NotchNotification) -> Bool { a.id == b.id }
}

/// Общее состояние панели: текущая вкладка, всплывающие подсказки, уведомления.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "lastTab") ?? "") ?? .music {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "lastTab") }
    }
    /// Короткая подсказка в шапке панели («Скопировано»).
    @Published var toast: String?
    /// Пока true, панель не сворачивается сама (например, идёт телесуфлёр).
    @Published var pinnedOpen = false
    /// Сейчас к чёлке тащат файл — из неё выехала полоса действий.
    @Published var fileDragActive = false
    /// Какие файлы тащат (чтобы погасить неподходящие действия, например «Конвертацию» не для картинок).
    @Published var dragURLs: [URL] = []
    /// До этого момента панель не сворачивается (например, сразу после смены размера).
    var holdOpenUntil = Date.distantPast
    /// Когда панель последний раз сворачивали: через 10 минут без хаба он снова открывается на «Музыке».
    var lastPanelClose = Date()

    func holdOpen(for seconds: TimeInterval) { holdOpenUntil = Date().addingTimeInterval(seconds) }
    /// Уведомление, которое сейчас показывается в чёлке.
    @Published private(set) var notification: NotchNotification?

    /// Пришедшее, пока висит другое: сменит его, как только то провисит минимум.
    private var pending: NotchNotification?
    private var shownAt = Date.distantPast
    private var toastWork: DispatchWorkItem?
    private var notifWork: DispatchWorkItem?

    func flash(_ text: String) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Показать уведомление в чёлке. Каждое висит своё время (настройка «Сколько висит уведомление»),
    /// наведение и раскрытие хаба его не убирают. Новое не ждёт, пока старое досидит до конца:
    /// сменяет его, как только то провисело полторы секунды (все остаются в истории).
    func post(_ n: NotchNotification) {
        DispatchQueue.main.async {
            NotificationHistory.shared.add(n)
            guard self.notification != nil else { self.show(n); return }
            self.pending = n   // из нескольких пришедших подряд показываем самое свежее
            let wait = max(0, Self.minVisible - Date().timeIntervalSince(self.shownAt))
            self.schedule(after: wait)
        }
    }

    private static let minVisible: TimeInterval = 1.5

    private func show(_ n: NotchNotification) {
        pending = nil
        notification = n
        shownAt = Date()
        n.onShown?()
        schedule(after: max(2, Prefs.shared.notifSeconds))
    }

    private func schedule(after seconds: TimeInterval) {
        notifWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.advance() }
        notifWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func advance() {
        if let next = pending { show(next) } else { notification = nil }
    }

    func dismissNotification() {
        notifWork?.cancel()
        advance()
    }

    /// Открыть панель (на нужной вкладке).
    func open(_ tab: Tab? = nil) {
        if let tab {
            self.tab = tab
            lastPanelClose = Date()   // вкладку выбрали явно — не подменять её «Музыкой»
        }
        NotchManager.shared.openOnActiveScreen()
    }
}
