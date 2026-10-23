import SwiftUI
import AppKit

struct CalendarTabView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var notion = NotionService.shared
    @ObservedObject private var mac = CalendarEventsModel.shared
    @AppStorage("calendar.folder") private var folder = "today"
    @State private var checkResult: String?
    @State private var checking = false

    private let timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MH.t1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if prefs.calendarSource == .notion && notion.isLoading {
                    ProgressView().controlSize(.small)
                }
                MHIconButton("arrow.clockwise", help: "Обновить", size: 26) { refresh(force: true) }
                MHSegmented(options: [(CalendarSource.notion, "Notion"), (CalendarSource.mac, "Календарь Mac")],
                            selection: $prefs.calendarSource)
            }
            if prefs.calendarSource == .notion {
                notionBody
            } else {
                macBody
            }
        }
        .panelMeta(meta)
        .onAppear { refresh(force: false) }
        .onChange(of: prefs.calendarSource) { refresh(force: false) }
        .onReceive(timer) { _ in refresh(force: true) }
    }

    private var heading: String {
        if prefs.calendarSource == .mac {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "d MMMM"
            return "Сегодня, " + f.string(from: Date())
        }
        return "Задачи · " + folderTitle(folder)
    }

    private var meta: String {
        if prefs.calendarSource == .mac { return "Календарь Mac" }
        if let d = notion.lastUpdate { return "Notion · " + Fmt.ago(d) }
        return "Notion"
    }

    private func refresh(force: Bool) {
        if prefs.calendarSource == .notion {
            notion.refresh(force: force)
        } else {
            mac.load()
        }
    }

    // MARK: Notion

    @ViewBuilder private var notionBody: some View {
        if !notion.isConfigured {
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "link",
                               title: "Подключите Notion",
                               subtitle: "Вставьте токен интеграции и ссылку на базу задач в настройках — и задачи Джарвиса появятся здесь")
                Button("Открыть настройки") { AppModel.shared.tab = .settings }
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if notion.tasks.isEmpty, let error = notion.error {
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Не удалось загрузить задачи", subtitle: error)
                Button("Повторить") { refresh(force: true) }
                    .buttonStyle(MHButtonStyle())
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                folderColumn
                    .frame(width: 170)
                taskList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct FolderItem: Identifiable {
        let id: String
        let title: String
        let icon: String
        let color: Color
    }

    private var listFolders: [FolderItem] {
        [
            FolderItem(id: "today", title: "Сегодня", icon: "sun.max", color: MH.yellow),
            FolderItem(id: "upcoming", title: "Предстоящие", icon: "calendar", color: MH.lightBlue),
            FolderItem(id: "overdue", title: "Просрочено", icon: "exclamationmark.circle", color: MH.red),
            FolderItem(id: "nodate", title: "Без срока", icon: "tray", color: MH.t3),
            FolderItem(id: "all", title: "Все невыполненные", icon: "list.bullet", color: MH.t2)
        ]
    }

    private var sphereFolders: [FolderItem] {
        (notion.schema?.sphereOptions ?? []).map {
            FolderItem(id: "s:" + $0.name, title: NotionService.clean($0.name), icon: "folder", color: NotionService.color(named: $0.color))
        }
    }

    private var projectFolders: [FolderItem] {
        (notion.schema?.projectOptions ?? []).map {
            FolderItem(id: "p:" + $0.name, title: NotionService.clean($0.name), icon: "folder.fill", color: NotionService.color(named: $0.color))
        }
    }

    private func folderTitle(_ id: String) -> String {
        let all = listFolders + sphereFolders + projectFolders
        if let f = all.first(where: { $0.id == id }) { return f.title }
        if id.hasPrefix("s:") || id.hasPrefix("p:") { return NotionService.clean(String(id.dropFirst(2))) }
        return "Сегодня"
    }

    private var folderColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                folderHeader("Списки")
                ForEach(listFolders) { folderRow($0) }
                if !sphereFolders.isEmpty {
                    folderHeader("Сферы")
                    ForEach(sphereFolders) { folderRow($0) }
                }
                if notion.schema?.projectProp != nil {
                    folderHeader("Проекты")
                    if projectFolders.isEmpty {
                        Text("Пока нет проектов")
                            .font(.system(size: 11))
                            .foregroundStyle(MH.t3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(projectFolders) { folderRow($0) }
                    }
                }
            }
        }
    }

    private func folderHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(MH.t3)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func folderRow(_ item: FolderItem) -> some View {
        let count = notion.count(in: item.id)
        let selected = folder == item.id
        return Button {
            folder = item.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(item.color)
                    .frame(width: 14)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(MH.t1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(item.id == "overdue" ? MH.red : MH.t3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.white.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var taskList: some View {
        let items = notion.tasks(in: folder)
        if notion.tasks.isEmpty && !notion.isLoading && notion.lastUpdate != nil {
            // Notion ответил, но задач нет — показать, куда именно подключены, а не просто пустоту.
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "tray",
                               title: "Notion вернул 0 задач",
                               subtitle: "Подключена база «\(notion.sourceTitle ?? "без названия")». Если задачи Джарвиса лежат в другой — нажмите «Проверить подключение» или вставьте ссылку на базу «Задачи» в настройках")
                HStack(spacing: 8) {
                    Button(checking ? "Проверяю…" : "Проверить подключение") {
                        checking = true
                        Task { @MainActor in
                            let r = await notion.testConnection()
                            checkResult = r.1
                            checking = false
                        }
                    }
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                    .disabled(checking)
                    Button("Диагностика") { Diagnostics.copy() }
                        .buttonStyle(MHButtonStyle())
                }
                if let checkResult {
                    Text(checkResult).font(.system(size: 11)).foregroundStyle(MH.t2).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            // Папка пуста, но невыполненные задачи есть в других — подсказать, где они.
            let elsewhere = folder == "all" ? 0 : notion.count(in: "all")
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "checkmark.circle",
                               title: notion.isLoading && notion.tasks.isEmpty ? "Загружаю задачи…" : "В этой папке задач нет",
                               subtitle: elsewhere > 0 ? "Невыполненных задач в других папках: \(elsewhere)"
                                                       : (folder == "today" ? "На сегодня всё сделано" : ""))
                if elsewhere > 0 {
                    Button("Показать все") { folder = "all" }
                        .buttonStyle(MHButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items) { task in
                        NotionTaskRow(task: task)
                    }
                }
            }
        }
    }

    // MARK: Календарь Mac

    @ViewBuilder private var macBody: some View {
        switch mac.access {
        case .denied:
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "calendar.badge.exclamationmark",
                               title: "Нет доступа к Календарю",
                               subtitle: "Разрешите Magic Hub доступ: Системные настройки → Конфиденциальность → Календари")
                Button("Открыть настройки") { CalendarEventsModel.openPrivacySettings() }
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unknown:
            EmptyStateView(systemImage: "calendar", title: "Загружаю календарь…")
        case .granted:
            if mac.items.isEmpty {
                EmptyStateView(systemImage: "checkmark.circle", title: "Встреч больше нет", subtitle: "В ближайшие сутки календарь пуст")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(mac.items) { item in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.color)
                                    .frame(width: 4)
                                Text(CalendarEventsModel.timeText(item))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(MH.t2)
                                    .frame(width: 130, alignment: .leading)
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MH.t1)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.calendar)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MH.t3)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(MH.card))
                        }
                    }
                }
            }
        }
    }
}

/// Строка задачи Notion.
private struct NotionTaskRow: View {
    let task: NotionTask
    @ObservedObject private var notion = NotionService.shared

    var body: some View {
        let done = notion.isClosed(task)
        HStack(alignment: .top, spacing: 10) {
            Button {
                notion.toggleDone(task)
            } label: {
                ZStack {
                    Circle()
                        .stroke(done ? MH.accent : Color(hex: "636366"), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if done {
                        Circle().fill(MH.accent).frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(done ? "Снять отметку" : "Отметить выполненной")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if let url = URL(string: task.url), !task.url.isEmpty { NSWorkspace.shared.open(url) }
                } label: {
                    Text(task.title)
                        .font(.system(size: 13))
                        .foregroundStyle(done ? MH.t3 : MH.t1)
                        .strikethrough(done)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Открыть в Notion")

                HStack(spacing: 8) {
                    if let due = NotionService.dueText(task) {
                        Text(due).foregroundStyle(NotionService.isOverdue(task) && !done ? MH.red : MH.t2)
                    }
                    if let p = task.priority {
                        HStack(spacing: 4) {
                            Circle().fill(NotionService.priorityColor(p)).frame(width: 6, height: 6)
                            Text(NotionService.clean(p)).foregroundStyle(MH.t2)
                        }
                    }
                    if let s = task.sphere {
                        let c = notion.sphereColor(s)
                        Text(NotionService.clean(s))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .foregroundStyle(c)
                            .background(Capsule().fill(c.opacity(0.15)))
                    }
                    if let p = task.project {
                        Text("· " + NotionService.clean(p)).foregroundStyle(notion.projectColor(p))
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(MH.card))
    }
}
