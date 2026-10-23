import Foundation
import SwiftUI
import EventKit
import AppKit

/// События Календаря Mac на ближайшие сутки.
final class CalendarEventsModel: ObservableObject {
    static let shared = CalendarEventsModel()

    enum Access { case unknown, granted, denied }

    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let calendar: String
        let color: Color
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var items: [Item] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    func load() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            fetch()
        case .notDetermined:
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    self.access = granted ? .granted : .denied
                    if granted { self.fetch() }
                }
            }
        default:
            access = .denied
        }
    }

    private func fetch() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.fetch()
            }
        }
        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { a, b in
            let x: Date = a.startDate ?? Date.distantPast
            let y: Date = b.startDate ?? Date.distantPast
            return x < y
        }
        items = events.map { e in
            let start: Date = e.startDate ?? now
            let finish: Date = e.endDate ?? start
            let nsColor: NSColor = e.calendar?.color ?? NSColor.systemBlue
            return Item(id: (e.eventIdentifier ?? UUID().uuidString) + "-\(start.timeIntervalSince1970)",
                        title: (e.title ?? "").isEmpty ? "Без названия" : (e.title ?? ""),
                        start: start,
                        end: finish,
                        allDay: e.isAllDay,
                        calendar: e.calendar?.title ?? "",
                        color: Color(nsColor: nsColor))
        }
    }

    static func timeText(_ item: Item) -> String {
        if item.allDay { return "Весь день" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if item.start <= Date() { return "Сейчас · до \(f.string(from: item.end))" }
        let prefix = Calendar.current.isDateInTomorrow(item.start) ? "Завтра " : ""
        return prefix + f.string(from: item.start) + " – " + f.string(from: item.end)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
