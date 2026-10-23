import SwiftUI
import AppKit

private enum SysPopTab: String { case system, power, fans, boost }

/// Окошко по клику на цифры в меню-баре.
struct SystemPopoverView: View {
    let onSettings: () -> Void
    let onActivityMonitor: () -> Void

    @ObservedObject private var mon = SysMonitor.shared
    @ObservedObject private var fans = FanController.shared
    /// Окошко создаётся заново при каждом открытии — выбранная вкладка запоминается.
    @AppStorage("sysPopover.tab") private var tab: SysPopTab = .system

    var body: some View {
        VStack(spacing: 12) {
            header
            Group {
                switch tab {
                case .system: SysSystemTab(mon: mon)
                case .power: SysPowerTab(mon: mon)
                case .fans: SysFansTab(mon: mon, fans: fans)
                case .boost: SysBoostTab(openFans: { tab = .fans })
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(hex: "1E1E20"))
        .foregroundStyle(MH.t1)
        .environment(\.colorScheme, .dark)
        .onAppear { if tab == .fans && !fans.hasFans { tab = .system } }
    }

    private var tabOptions: [(SysPopTab, String)] {
        var o: [(SysPopTab, String)] = [(.system, "Система"), (.power, "Питание")]
        if fans.hasFans { o.append((.fans, "Вентиляторы")) }
        o.append((.boost, "Ускорение"))
        return o
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SysLogo(size: 30)
                Text("Magic Hub").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
            }
            MHSegmented(options: tabOptions, selection: $tab)
                .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onSettings) {
                Label("Настройки", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MHButtonStyle())
            Button(action: onActivityMonitor) {
                Label("Мониторинг", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MHButtonStyle())
        }
    }
}

/// Логотип: чёрное матовое сердечко на сером круге с размытыми краями.
struct SysLogo: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: "A1A1A6"), Color(hex: "8E8E93"), Color(hex: "8E8E93").opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size / 2))
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.36))
                .foregroundStyle(Color(hex: "151515"))
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Общие кусочки

private struct SysCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

private struct SysKV: View {
    let key: String
    let value: String
    var valueColor: Color = MH.t2

    var body: some View {
        HStack {
            Text(key).foregroundStyle(MH.t2)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
        .font(.system(size: 12))
    }
}

/// Простой график-линия по истории значений.
struct SysSparkline: View {
    let values: [Double]
    var maxValue: Double = 1
    var color: Color = MH.accent

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(maxValue, values.max() ?? 0, 0.0001)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0.5))
                    p.addLine(to: CGPoint(x: w, y: 0.5))
                }
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.white.opacity(0.15))
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(values.count - 1)
                            let y = h - h * CGFloat(min(v, maxV) / maxV)
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
        }
    }
}

private struct SysAppRow: View {
    let app: SysProcInfo
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(MH.t2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 4).fill(MH.card3))
                }
            }
            .frame(width: 16, height: 16)
            Text(app.name).lineLimit(1)
            Spacer()
            Text(value).foregroundStyle(MH.t2)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Система

private struct SysSystemTab: View {
    @ObservedObject var mon: SysMonitor
    @State private var showCores = true
    @State private var showMemApps = false

    var body: some View {
        let s = mon.snap
        VStack(spacing: 10) {
            HStack {
                Label("Температура CPU", systemImage: "thermometer.medium")
                    .font(.system(size: 12)).foregroundStyle(MH.t2)
                Spacer()
                Text(s.cpuTemp.map { "\(Int($0.rounded())) °C" } ?? "—")
                    .font(.system(size: 22, weight: .bold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))

            SysCard {
                HStack(spacing: 10) {
                    Button { showCores.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showCores ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Нагрузка")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    MHBar(value: s.cpu, color: MH.accent, height: 6)
                    Text("\(Int((s.cpu * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).frame(width: 36, alignment: .trailing)
                }
                SysSparkline(values: mon.cpuHistory, maxValue: 1, color: MH.accent).frame(height: 32)
                if showCores && !s.perCore.isEmpty {
                    coreBars(s)
                }
                if !mon.topCPU.isEmpty {
                    Text("Приложения, нагружающие CPU").font(.system(size: 11)).foregroundStyle(MH.t3).padding(.top, 2)
                    ForEach(mon.topCPU) { app in
                        SysAppRow(app: app, value: Fmt.number(app.cpu, maxFraction: 1) + "%")
                    }
                }
            }

            SysCard {
                HStack(spacing: 8) {
                    Text("Давление памяти").font(.system(size: 12))
                    Spacer()
                    pressurePill(s.memory.pressure)
                    Text("\(Fmt.bytes(s.memory.used)) / \(Fmt.bytes(s.memory.total))")
                        .font(.system(size: 12, weight: .semibold))
                }
                SysKV(key: "Сжатая", value: Fmt.bytes(s.memory.compressed))
                SysKV(key: "Кэшированные файлы", value: Fmt.bytes(s.memory.cached))
                SysKV(key: "Подкачка", value: Fmt.bytes(s.memory.swap))
                if !mon.topMem.isEmpty {
                    Button { showMemApps.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showMemApps ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Приложения по памяти")
                        }
                        .font(.system(size: 11)).foregroundStyle(MH.t3)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    if showMemApps {
                        ForEach(mon.topMem) { app in
                            SysAppRow(app: app, value: Fmt.bytes(app.memBytes))
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text("Время работы: \(Fmt.duration(s.uptime))")
                Spacer()
            }
            .font(.system(size: 12)).foregroundStyle(MH.t2)
            .padding(.horizontal, 4)
        }
    }

    private func pressurePill(_ level: Int) -> some View {
        switch level {
        case 4: return StatusPill(text: "Критично", color: MH.red)
        case 2: return StatusPill(text: "Предупреждение", color: MH.yellow)
        default: return StatusPill(text: "Норма", color: MH.green)
        }
    }

    @ViewBuilder private func coreBars(_ s: SysSnapshot) -> some View {
        let per = s.perCore
        // На Apple Silicon первыми идут ядра эффективности, затем производительности.
        let e = s.eCores > 0 ? Array(per.prefix(s.eCores)) : []
        let p = s.eCores > 0 ? Array(per.dropFirst(s.eCores)) : per
        HStack(alignment: .bottom, spacing: 10) {
            coreGroup(p, title: s.eCores > 0 ? "Производительность ×\(p.count)" : "Ядра ×\(p.count)")
            if !e.isEmpty {
                coreGroup(e, title: "Эффективность ×\(e.count)")
            }
        }
    }

    private func coreGroup(_ values: [Double], title: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(MH.card3)
                        RoundedRectangle(cornerRadius: 3).fill(MH.t2)
                            .frame(height: max(2, 34 * CGFloat(min(1, v))))
                    }
                    .frame(height: 34)
                }
            }
            Text(title).font(.system(size: 10)).foregroundStyle(MH.t3)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Питание

private struct SysPowerTab: View {
    @ObservedObject var mon: SysMonitor
    @State private var showApps = false

    var body: some View {
        if let b = mon.snap.battery {
            VStack(spacing: 10) {
                SysCard {
                    HStack(spacing: 10) {
                        Label("Батарея", systemImage: batteryIcon(b))
                            .font(.system(size: 12))
                            .frame(width: 80, alignment: .leading)
                        MHBar(value: Double(b.percent) / 100, color: batteryColor(b), height: 6)
                        Text("\(b.percent)%").font(.system(size: 12, weight: .semibold)).frame(width: 36, alignment: .trailing)
                    }
                    SysSparkline(values: mon.batteryHistory, maxValue: 1, color: MH.green).frame(height: 26)
                    SysKV(key: "Источник", value: b.isCharging ? "заряжается" : (b.onAC ? "от сети" : "от батареи"))
                    SysKV(key: "Температура батареи", value: b.temperature.map { "\(Int($0.rounded())) °C" } ?? "—")
                }
                SysCard {
                    HStack {
                        Label("Система", systemImage: "bolt.fill").font(.system(size: 12))
                            .foregroundStyle(MH.orange)
                        Spacer()
                        Text(b.systemWatts.map { Fmt.number($0, maxFraction: 1) + " Вт" } ?? "—")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    SysSparkline(values: mon.powerHistory, maxValue: 10, color: MH.orange).frame(height: 30)
                    if let w = b.batteryWatts {
                        SysKV(key: w >= 0 ? "Батарея принимает" : "Батарея отдаёт", value: Fmt.number(abs(w), maxFraction: 1) + " Вт")
                    }
                    SysKV(key: "Осталось (оценка системы)", value: b.timeRemaining.map { Fmt.duration($0) } ?? (b.onAC ? "—" : "считается…"))
                    SysKV(key: "Состояние батареи",
                          value: [b.health.map { "\(Int($0.rounded()))%" }, b.cycles.map { "\($0) циклов" }].compactMap { $0 }.joined(separator: " · "))
                    if let raw = b.rawHealth, let h = b.health, abs(raw - h) >= 2 {
                        SysKV(key: "Вмещает сейчас", value: "\(Int(raw.rounded()))%")
                            .help("Сырая ёмкость от контроллера батареи: плавает с температурой и калибровкой. В «Системных настройках» — значение «Состояние батареи»")
                    }
                }
                SysCard {
                    Button { showApps.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showApps ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Приложения с высоким энергопотреблением")
                            Spacer()
                        }
                        .font(.system(size: 12)).foregroundStyle(MH.t2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showApps {
                        ForEach(mon.topCPU) { app in
                            SysAppRow(app: app, value: Fmt.number(app.cpu, maxFraction: 1) + "% CPU")
                        }
                    }
                }
            }
        } else {
            EmptyStateView(systemImage: "powerplug", title: "Батареи нет", subtitle: "Mac работает от сети")
                .frame(height: 140)
        }
    }

    private func batteryIcon(_ b: SysBattery) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(_ b: SysBattery) -> Color {
        if b.isCharging || b.onAC { return MH.green }
        if b.percent < 15 { return MH.red }
        if b.percent < 35 { return MH.yellow }
        return MH.green
    }
}

// MARK: - Вентиляторы

private struct SysFansTab: View {
    @ObservedObject var mon: SysMonitor
    @ObservedObject var fans: FanController
    @State private var helperInstalled = PrivilegedHelper.isInstalled
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 10) {
            if mon.snap.fans.isEmpty {
                EmptyStateView(systemImage: "fan", title: "Вентиляторы не найдены").frame(height: 120)
            } else {
                ForEach(mon.snap.fans) { fan in
                    SysFanRow(fan: fan, fans: fans, enabled: helperInstalled)
                }
            }
            if !helperInstalled {
                SysCard {
                    Text("Чтобы менять скорость, нужен помощник с правами администратора — пароль спросят один раз.")
                        .font(.system(size: 12)).foregroundStyle(MH.t2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Разрешить (один раз ввести пароль)") {
                        let r = PrivilegedHelper.install()
                        helperInstalled = PrivilegedHelper.isInstalled
                        installError = r.ok ? nil : r.error
                    }
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                    if let installError {
                        Text(installError).font(.system(size: 11)).foregroundStyle(MH.orange)
                    }
                }
            }
            if let err = fans.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(MH.orange)
            }
            Text("При выходе из Magic Hub вентиляторы возвращаются в авто-режим.")
                .font(.system(size: 11)).foregroundStyle(MH.t3)
        }
    }
}

private struct SysFanRow: View {
    let fan: FanInfo
    @ObservedObject var fans: FanController
    let enabled: Bool
    @State private var target: Double = 0

    var body: some View {
        let manual = fans.isManual(fan.id)
        SysCard {
            HStack {
                Label("Вентилятор \(fan.id + 1)", systemImage: "fan").font(.system(size: 12))
                Spacer()
                Text("\(Int(fan.actual)) об/мин").font(.system(size: 13, weight: .semibold))
            }
            SysKV(key: "Диапазон", value: "\(Int(fan.min))–\(Int(fan.max)) об/мин")
            HStack {
                Text("Режим").font(.system(size: 12)).foregroundStyle(MH.t2)
                Spacer()
                MHSegmented(options: [(false, "Авто"), (true, "Вручную")], selection: Binding(
                    get: { manual },
                    set: { newValue in
                        guard enabled else { return }
                        if newValue {
                            let start = target > 0 ? target : max(fan.actual, fan.min)
                            target = start
                            fans.setManual(fan.id, rpm: start)
                        } else {
                            fans.setAuto(fan.id)
                        }
                    }
                ))
                .opacity(enabled ? 1 : 0.5)
            }
            if manual && fan.max > fan.min {
                HStack(spacing: 8) {
                    Slider(value: $target, in: fan.min...fan.max, step: 100, onEditingChanged: { editing in
                        if !editing { fans.setManual(fan.id, rpm: target) }
                    })
                    .tint(MH.accent)
                    Text("\(Int(target))").font(.system(size: 12, weight: .semibold)).frame(width: 46, alignment: .trailing)
                }
            }
        }
        .onAppear {
            target = fans.manualTargets[fan.id] ?? max(fan.actual, fan.min)
        }
    }
}
