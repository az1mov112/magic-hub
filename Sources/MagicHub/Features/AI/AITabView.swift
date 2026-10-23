import SwiftUI

/// Вкладка «ИИ-агенты»: Джарвис слева, Claude справа.
struct AITabView: View {
    @ObservedObject private var jarvis = JarvisMonitor.shared
    @ObservedObject private var claude = ClaudeUsageMonitor.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AIJarvisCard()
            AIClaudeCard()
        }
        .panelMeta(claude.scanning ? "обновляю…" : "Claude Code · Джарвис")
        .onAppear {
            jarvis.refresh()
            claude.refreshAll()
        }
    }
}

private struct AICardBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(MH.cardDeep))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MH.line, lineWidth: 1))
    }
}

private struct AIRow: View {
    let label: String
    let value: String
    var color: Color = MH.t1

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(MH.t3)
            Spacer(minLength: 6)
            Text(value).foregroundStyle(color).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Джарвис

private struct AIJarvisCard: View {
    @ObservedObject private var jarvis = JarvisMonitor.shared
    @State private var confirmHard = false

    var body: some View {
        let s = jarvis.state
        AICardBox {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(MH.t1)
                Text("Джарвис").font(.system(size: 14, weight: .semibold))
                Spacer()
                status(s)
            }
            if !s.found {
                Spacer()
                Text("Джарвис не найден на этом Mac. Если он у вас есть — укажите его папку в настройках.")
                    .font(.system(size: 12)).foregroundStyle(MH.t2)
                Button("Открыть настройки") { AppModel.shared.tab = .settings }
                    .buttonStyle(MHButtonStyle())
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        taskBox(s)
                        AIRow(label: "Работает", value: s.uptime.map(Fmt.duration) ?? "—")
                        AIRow(label: "Первый ответ", value: latency(s), color: latencyColor(s))
                        AIRow(label: "Telegram", value: pollerText(s.pollers), color: s.pollers == 1 ? MH.green : MH.red)
                        contextRow(s)
                        AIRow(label: "Ошибки сегодня", value: s.errorsToday == 0 ? "нет" : "\(s.errorsToday)", color: s.errorsToday == 0 ? MH.t1 : MH.orange)
                        if let e = s.lastError, let issue = s.lastIssue, let d = s.lastErrorDate, Date().timeIntervalSince(d) < 6 * 3600 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Fmt.ago(d)): \(issue.title)").font(.system(size: 11, weight: .semibold)).foregroundStyle(MH.orange)
                                Text(issue.hint).font(.system(size: 11)).foregroundStyle(MH.t2).lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .help(e)
                        }
                        AIRow(label: "Перезапуски сегодня", value: "\(s.restartsToday)")
                        AIRow(label: "Медиана хода", value: s.medianTurn.map(Fmt.duration) ?? "—",
                              color: (s.medianTurn ?? 0) > 60 ? MH.orange : MH.t1)
                        if s.compactionsToday > 0 {
                            AIRow(label: "Сжатий контекста сегодня", value: "\(s.compactionsToday)")
                        }
                        if let net = jarvis.network {
                            Text(net).font(.system(size: 11)).foregroundStyle(MH.t2)
                        }
                    }
                }
                if let msg = jarvis.actionMessage {
                    Text(msg).font(.system(size: 11)).foregroundStyle(MH.t2).lineLimit(2)
                }
                buttons(s)
            }
        }
    }

    @ViewBuilder private func status(_ s: JarvisState) -> some View {
        if !s.found {
            StatusPill(text: "Не найден", color: MH.t3)
        } else if !s.running {
            StatusPill(text: "Не запущен", color: MH.red)
        } else if s.hung {
            StatusPill(text: "Завис?", color: MH.red, pulse: true)
        } else if s.busy {
            StatusPill(text: "Занят", color: MH.yellow, pulse: true)
        } else {
            StatusPill(text: "Свободен", color: MH.green)
        }
    }

    @ViewBuilder private func taskBox(_ s: JarvisState) -> some View {
        if let task = s.currentTask {
            let elapsed = s.taskStarted.map { Fmt.clock(Date().timeIntervalSince($0)) } ?? ""
            let prefix = s.busy ? "Сейчас" : "Последняя задача"
            Text("\(prefix): «\(task)»\(s.busy && !elapsed.isEmpty ? " · " + elapsed : "")")
                .font(.system(size: 12))
                .foregroundStyle(MH.t2)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
        }
    }

    private func contextRow(_ s: JarvisState) -> some View {
        let tokens = Double(s.contextTokens ?? 0)
        let ratio = tokens / 150_000
        let color: Color = tokens > 150_000 ? MH.red : (tokens > 100_000 ? MH.orange : MH.green)
        return HStack(spacing: 8) {
            Text("Контекст").foregroundStyle(MH.t3)
            MHBar(value: ratio, color: color)
            Text(s.contextTokens == nil ? "—" : Fmt.tokens(tokens)).lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private func latency(_ s: JarvisState) -> String {
        guard let l = s.firstReplyLatency else { return "—" }
        return s.waitingFirstReply ? "ждёт \(Fmt.duration(l))" : Fmt.duration(l)
    }

    private func latencyColor(_ s: JarvisState) -> Color {
        guard let l = s.firstReplyLatency else { return MH.t1 }
        if l > 180 { return MH.red }
        if l > 120 { return MH.orange }
        return s.waitingFirstReply ? MH.yellow : MH.green
    }

    private func pollerText(_ n: Int) -> String {
        switch n {
        case 0: return "нет связи"
        case 1: return "подключён"
        default: return "\(n) поллера — конфликт"
        }
    }

    private func buttons(_ s: JarvisState) -> some View {
        HStack(spacing: 6) {
            Button("Мягкий перезапуск") { jarvis.softRestart() }
                .buttonStyle(MHButtonStyle(kind: .prominent))
            Button(confirmHard ? "Точно?" : "Жёсткий") {
                if s.busy && !confirmHard {
                    confirmHard = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmHard = false }
                } else {
                    confirmHard = false
                    jarvis.hardRestart()
                }
            }
            .buttonStyle(MHButtonStyle(kind: .destructive))
            .help(s.busy ? "Джарвис занят: жёсткий перезапуск оборвёт задачу" : "launchctl kickstart -k")
            Spacer(minLength: 0)
            MHIconButton("network", help: "Проверить сеть", size: 26) { jarvis.checkNetwork() }
            MHIconButton("doc.text", help: "Открыть лог", size: 26) { jarvis.openLog() }
        }
    }
}

// MARK: - Claude

private struct AIClaudeCard: View {
    @ObservedObject private var claude = ClaudeUsageMonitor.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        AICardBox {
            HStack(spacing: 8) {
                Image(systemName: "asterisk").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: "D97757"))
                Text("Claude").font(.system(size: 14, weight: .semibold))
                if let plan = claude.plan {
                    Text(plan.capitalized).font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(MH.card3))
                        .foregroundStyle(MH.t2)
                }
                Spacer()
                Text(claude.sessions.isEmpty ? "нет активных сессий" : "активных: \(claude.sessions.count)")
                    .font(.system(size: 11)).foregroundStyle(MH.t3)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if prefs.claudeLimits {
                        if claude.limits.isEmpty {
                            Text(claude.limitsError ?? "Загружаю лимиты…").font(.system(size: 11)).foregroundStyle(MH.t3)
                        }
                        ForEach(claude.limits) { l in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(l.title)
                                    Spacer()
                                    Text("\(Int(l.utilization.rounded()))%").fontWeight(.semibold)
                                }
                                .font(.system(size: 12))
                                MHBar(value: l.utilization / 100, color: l.utilization > 90 ? MH.red : (l.utilization > 75 ? MH.orange : MH.accent))
                                if let r = l.resetsAt {
                                    Text("сброс " + resetText(r)).font(.system(size: 11)).foregroundStyle(MH.t3)
                                }
                            }
                        }
                        Rectangle().fill(MH.line).frame(height: 1)
                    }
                    if prefs.claudeCost {
                        AIRow(label: "Сегодня", value: "\(Fmt.tokens(claude.today.tokens)) ток. · ≈ \(Fmt.usd(claude.today.cost))")
                        AIRow(label: "Месяц по ценам API", value: "≈ \(Fmt.usd(claude.month.cost))")
                        Text("На подписке за токены не списывают — это для понимания масштаба.")
                            .font(.system(size: 10)).foregroundStyle(MH.t3)
                        Rectangle().fill(MH.line).frame(height: 1)
                    }
                    ForEach(claude.sessions) { s in
                        HStack(spacing: 6) {
                            Circle().fill(s.busy ? MH.yellow : MH.green).frame(width: 6, height: 6)
                            Text("\(s.name) — \(s.busy ? "работает" : "ждёт")").lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Fmt.ago(s.lastActivity)).foregroundStyle(MH.t3)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func resetText(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s <= 0 { return "сейчас" }
        if s < 24 * 3600 { return "через " + Fmt.duration(s) }
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "EEEE, HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Секции настроек

struct AISettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var jarvis = JarvisMonitor.shared

    var body: some View {
        SettingsSection("ИИ-агенты и Джарвис") {
            SettingsToggleRow("Следить за Джарвисом", isOn: $prefs.jarvisEnabled)
            SettingsRow("Джарвис", subtitle: foundText, subtitleColor: jarvis.state.found ? MH.green : MH.t3) {
                Button("Обновить") { jarvis.refresh() }.buttonStyle(MHButtonStyle())
            }
            SettingsRow("Папка бота", subtitle: "Пусто — найти автоматически") {
                TextField("~/Jarvis/bot", text: $prefs.jarvisBotDir)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingsRow("Служба launchd", subtitle: "Пусто — найти автоматически") {
                TextField("com.example.jarvis", text: $prefs.jarvisLabel)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingsRow("Папка скриптов и логов") {
                TextField("~/.jarvis", text: $prefs.jarvisHome)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingsToggleRow("Лимиты Claude (сессия и неделя)",
                              subtitle: "Неофициальный способ, как /usage — может сломаться после обновления Claude Code",
                              isOn: $prefs.claudeLimits)
            SettingsToggleRow("Траты по ценам API", subtitle: "Считаются по локальным логам Claude Code", isOn: $prefs.claudeCost)
            SettingsSegmentRow("Проверять Джарвиса каждые", options: [(5.0, "5 с"), (10.0, "10 с"), (30.0, "30 с"), (60.0, "1 мин")],
                               selection: $prefs.aiInterval)
        }
    }

    private var foundText: String {
        let s = jarvis.state
        guard s.found else { return "Не найден" }
        var parts: [String] = []
        if let d = s.botDir { parts.append((d as NSString).abbreviatingWithTildeInPath) }
        if let l = s.serviceLabel { parts.append(l) }
        return "Найден: " + parts.joined(separator: " · ")
    }
}

struct NotificationsSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var sample = 0

    var body: some View {
        SettingsSection("Уведомления в чёлке") {
            SettingsToggleRow("Джарвис принял задачу", isOn: $prefs.evTaskTaken)
            SettingsToggleRow("Джарвис закончил задачу", isOn: $prefs.evTaskDone)
            SettingsToggleRow("Ошибка или кончился лимит", isOn: $prefs.evError)
            SettingsToggleRow("Джарвис завис", subtitle: "Занят и молчит больше 10 минут", isOn: $prefs.evHang)
            SettingsToggleRow("Джарвис перезапустился или упал", isOn: $prefs.evRestart)
            SettingsButtonRow("Как это выглядит", buttonTitle: "Показать пример") { showSample() }
        }
    }

    private func showSample() {
        let samples = [
            NotchNotification(title: "Джарвис принял задачу", subtitle: "«Составить план тренировок на неделю»", kind: .progress),
            NotchNotification(title: "Джарвис закончил задачу", subtitle: "План тренировок · за 2 мин", kind: .success),
            NotchNotification(title: "Кончился лимит Claude", subtitle: "Сброс в 03:00 · Джарвис подождёт", kind: .warning),
            NotchNotification(title: "Джарвис, похоже, завис", subtitle: "Нет активности 12 мин посреди задачи", kind: .error),
            NotchNotification(title: "Джарвис перезапустился", subtitle: "Последний код выхода: 1", kind: .info)
        ]
        let n = samples[sample % samples.count]
        sample += 1
        NotchManager.shared.closeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { AppModel.shared.post(n) }
    }
}
