import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case music, shelf, clipboard, snippets, calendar, translate, notes
    case currency, teleprompter, calculator, ai, awake, settings

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
    enum Kind { case progress, success, warning, error, info }

    let id = UUID()
    var title: String
    var subtitle: String
    var kind: Kind
    /// SF Symbol слева. По умолчанию — значок Джарвиса.
    var icon: String = "sparkles"
    /// Что сделать по клику на уведомление (по умолчанию — открыть вкладку «ИИ-агенты»).
    var onTap: (() -> Void)? = nil

    var color: Color {
        switch kind {
        case .progress, .info: return MH.accent
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
    /// Сейчас к чёлке тащат файл — панель открыта на полке и ждёт, пока его отпустят.
    @Published var fileDragActive = false
    /// До этого момента панель не сворачивается (например, сразу после смены размера).
    var holdOpenUntil = Date.distantPast

    func holdOpen(for seconds: TimeInterval) { holdOpenUntil = Date().addingTimeInterval(seconds) }
    /// Уведомление, которое сейчас показывается в чёлке.
    @Published private(set) var notification: NotchNotification?

    private var queue: [NotchNotification] = []
    private var toastWork: DispatchWorkItem?
    private var notifWork: DispatchWorkItem?

    func flash(_ text: String) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Показать уведомление в чёлке (очередь, по 4,5 с каждое).
    func post(_ n: NotchNotification) {
        DispatchQueue.main.async {
            self.queue.append(n)
            if self.notification == nil { self.showNext() }
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { notification = nil; return }
        notification = queue.removeFirst()
        let work = DispatchWorkItem { [weak self] in self?.showNext() }
        notifWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    func dismissNotification() {
        notifWork?.cancel()
        showNext()
    }

    /// Открыть панель (на нужной вкладке).
    func open(_ tab: Tab? = nil) {
        if let tab { self.tab = tab }
        NotchManager.shared.openOnActiveScreen()
    }
}
