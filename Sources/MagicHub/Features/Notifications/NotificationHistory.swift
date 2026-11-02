import AppKit
import SwiftUI

/// История уведомлений, которые показывала чёлка: от приложений Mac, Джарвиса и самого хаба.
/// Хранится в папке приложения, последние 300 штук.
final class NotificationHistory: ObservableObject {
    static let shared = NotificationHistory()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let title: String
        let subtitle: String
        /// Приложение-источник (bundle id); nil — уведомление самого хаба или Джарвиса.
        let source: String?
        /// SF Symbol для уведомлений без приложения.
        let symbol: String
    }

    @Published private(set) var items: [Entry] = []

    private static let file = "notification-history.json"
    private static let limit = 300
    private var saveWork: DispatchWorkItem?

    init() {
        items = JSONStore.load([Entry].self, from: Self.file) ?? []
    }

    func add(_ n: NotchNotification) {
        items.insert(Entry(date: Date(), title: n.title, subtitle: n.subtitle, source: n.source, symbol: n.icon), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        scheduleSave()
    }

    func remove(_ entry: Entry) {
        items.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func clear() {
        items = []
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { JSONStore.save(snapshot, to: Self.file) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Значки приложений

    private var icons: [String: NSImage] = [:]

    func icon(for bundle: String) -> NSImage? {
        if let cached = icons[bundle] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundle] = image
        return image
    }
}

/// Вкладка «Уведомления»: всё, что приходило в чёлку, по дням.
struct NotificationsTabView: View {
    @ObservedObject private var history = NotificationHistory.shared
    @State private var query = ""

    private var filtered: [NotificationHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.items }
        return history.items.filter { ($0.title + " " + $0.subtitle).lowercased().contains(q) }
    }

    private struct DayGroup: Identifiable {
        let title: String
        let items: [NotificationHistory.Entry]
        var id: String { title }
    }

    /// По дням: «Сегодня», «Вчера», дата.
    private var groups: [DayGroup] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "d MMMM"
        var result: [(String, [NotificationHistory.Entry])] = []
        for item in filtered {
            let title = cal.isDateInToday(item.date) ? "Сегодня" : (cal.isDateInYesterday(item.date) ? "Вчера" : f.string(from: item.date))
            if let last = result.last, last.0 == title {
                result[result.count - 1].1.append(item)
            } else {
                result.append((title, [item]))
            }
        }
        return result.map { DayGroup(title: $0.0, items: $0.1) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if history.items.isEmpty {
                EmptyStateView(systemImage: "bell",
                               title: "Пока пусто",
                               subtitle: "Здесь будут все уведомления, которые приходили в чёлку")
            } else {
                HStack(spacing: 8) {
                    MHSearchField(text: $query, placeholder: "Поиск по уведомлениям")
                    ClipConfirmButton("Очистить") { history.clear() }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups) { group in
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.8)
                                .foregroundStyle(MH.t3)
                                .padding(.top, 6)
                                .padding(.leading, 4)
                            ForEach(group.items) { item in
                                NotificationHistoryRow(item: item)
                            }
                        }
                    }
                }
            }
        }
        .panelMeta(history.items.isEmpty ? "" : "\(history.items.count)")
    }
}

private struct NotificationHistoryRow: View {
    let item: NotificationHistory.Entry
    @State private var hover = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let source = item.source, let icon = NotificationHistory.shared.icon(for: source) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MH.t2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Circle().fill(MH.card2))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MH.t1).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(MH.t2).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(Self.time.string(from: item.date)).font(.system(size: 11)).foregroundStyle(MH.t3).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? MH.card2 : MH.card))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if let source = item.source, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
        .contextMenu {
            Button("Скопировать текст") {
                Clipboard.copy([item.title, item.subtitle].filter { !$0.isEmpty }.joined(separator: "\n"))
                AppModel.shared.flash("Скопировано")
            }
            Button("Удалить") { NotificationHistory.shared.remove(item) }
        }
    }
}
