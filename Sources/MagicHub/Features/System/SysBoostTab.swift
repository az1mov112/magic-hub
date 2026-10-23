import SwiftUI
import AppKit

/// Совет по ускорению Mac: что мешает и кнопка, которая это исправляет.
struct BoostTip: Identifiable {
    enum Level: Int { case bad = 0, warn = 1, ok = 2 }

    let id: String
    let level: Level
    let icon: String
    let title: String
    let detail: String
    var buttonTitle: String?
    var action: (() -> Void)?
    /// Программы, которые можно закрыть прямо отсюда.
    var apps: [BoostApp] = []
}

struct BoostApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let value: String
}

/// Проверка Mac: только то, что действительно влияет на скорость, — без «чистки кэшей» и прочего самообмана.
final class MacCheckup: ObservableObject {
    static let shared = MacCheckup()

    @Published private(set) var tips: [BoostTip] = []
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?

    private let queue = DispatchQueue(label: "app.magichub.checkup", qos: .userInitiated)

    /// Данные, собранные в фоне.
    private struct Facts {
        var uptime: TimeInterval = 0
        var diskFree: Double = 0
        var diskTotal: Double = 0
        var memory = SysMemory()
        var apps: [(app: NSRunningApplication, cpu: Double, mem: Double)] = []
        var system: [(name: String, cpu: Double)] = []
        var speedLimit: Int?
        var cpuTemp: Double?
        var backgroundServices = 0
    }

    func run(openFans: @escaping () -> Void) {
        guard !checking else { return }
        checking = true
        // Настройки интерфейса читаем на главном потоке.
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cpuTemp = SysMonitor.shared.snap.cpuTemp
        queue.async {
            var f = Self.collect()
            f.cpuTemp = cpuTemp
            DispatchQueue.main.async {
                self.tips = Self.makeTips(f, reduceTransparency: reduceTransparency, reduceMotion: reduceMotion, openFans: openFans)
                self.checking = false
                self.checkedAt = Date()
            }
        }
    }

    // MARK: Сбор

    private static func collect() -> Facts {
        var f = Facts()
        f.uptime = SysCtl.uptime()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            f.diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            f.diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
        f.memory = SysMemory.read()

        // Процессы: помощники (Chrome Helper и т.п.) складываем в их программу — по пути к .app.
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var byApp: [pid_t: (cpu: Double, mem: Double)] = [:]
        var system: [String: Double] = [:]
        let ps = Shell.run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="])
        for line in ps.out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]) else { continue }
            let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
            let mem = (Double(parts[2]) ?? 0) * 1024
            let path = String(parts[3])
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                if let app = regular.first(where: { $0.bundleURL?.path == bundle }) {
                    var e = byApp[app.processIdentifier] ?? (0, 0)
                    e.cpu += cpu
                    e.mem += mem
                    byApp[app.processIdentifier] = e
                    continue
                }
            }
            if cpu >= 1 {
                let name = (path as NSString).lastPathComponent
                system[name, default: 0] += cpu
            }
        }
        f.apps = regular.compactMap { app -> (app: NSRunningApplication, cpu: Double, mem: Double)? in
            guard let e = byApp[app.processIdentifier] else { return nil }
            return (app: app, cpu: e.cpu, mem: e.mem)
        }
        f.system = system.map { (name: $0.key, cpu: $0.value) }.sorted { $0.cpu > $1.cpu }

        // Сброс частоты из-за перегрева (Intel): pmset пишет CPU_Speed_Limit < 100.
        let therm = Shell.run("/usr/bin/pmset", ["-g", "therm"]).out
        if let r = therm.range(of: #"CPU_Speed_Limit\s*=\s*(\d+)"#, options: .regularExpression) {
            f.speedLimit = Int(therm[r].filter(\.isNumber))
        }

        // Сторонние фоновые службы, которые стартуют вместе с Mac.
        let fm = FileManager.default
        for dir in ["~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            let path = AppPaths.expand(dir)
            let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            f.backgroundServices += items.filter { $0.hasSuffix(".plist") && !$0.hasPrefix("com.apple.") }.count
        }
        return f
    }

    // MARK: Советы

    private static func makeTips(_ f: Facts, reduceTransparency: Bool, reduceMotion: Bool,
                                 openFans: @escaping () -> Void) -> [BoostTip] {
        var tips: [BoostTip] = []
        let intel = !SysCtl.isAppleSilicon

        // Перегрев.
        if let limit = f.speedLimit, limit < 100 {
            tips.append(BoostTip(
                id: "heat", level: limit < 70 ? .bad : .warn, icon: "thermometer.high",
                title: "Перегрев: процессор работает на \(limit)% частоты",
                detail: "Mac сбрасывает частоту, чтобы остыть, — отсюда тормоза. Поставьте вентилятор на максимум, не держите Mac на мягком и закройте тяжёлые программы ниже.",
                buttonTitle: FanController.shared.hasFans ? "Вентиляторы" : nil,
                action: FanController.shared.hasFans ? openFans : nil))
        } else if let t = f.cpuTemp, t >= 90 {
            tips.append(BoostTip(
                id: "heat", level: .warn, icon: "thermometer.high",
                title: "Процессор горячий: \(Int(t))°",
                detail: "Ещё немного — и Mac начнёт сбрасывать частоту. Поможет вентилятор на максимум и твёрдая поверхность под Mac.",
                buttonTitle: FanController.shared.hasFans ? "Вентиляторы" : nil,
                action: FanController.shared.hasFans ? openFans : nil))
        } else {
            tips.append(BoostTip(id: "heat", level: .ok, icon: "thermometer.medium", title: "Перегрева нет", detail: ""))
        }

        // Программы, которые грузят процессор.
        let cpuHogs = f.apps.filter { $0.cpu >= 30 }.sorted { $0.cpu > $1.cpu }.prefix(3)
        if !cpuHogs.isEmpty {
            tips.append(BoostTip(
                id: "cpu", level: .warn, icon: "cpu",
                title: "Программы нагружают процессор",
                detail: "Закройте ненужные — Mac станет быстрее и холоднее.",
                apps: cpuHogs.map { BoostApp(id: $0.app.processIdentifier, name: $0.app.localizedName ?? "Программа",
                                            icon: $0.app.icon, value: "\(Int($0.cpu.rounded()))%") }))
        }
        if let sys = f.system.first(where: { $0.cpu >= 40 }), let hint = systemHint(sys.name) {
            tips.append(BoostTip(id: "system", level: .warn, icon: "gearshape.2",
                                 title: "\(hint.title): \(Int(sys.cpu.rounded()))% процессора", detail: hint.detail))
        }

        // Память.
        let swapHeavy = f.memory.swap > 1.5 * 1_073_741_824
        if f.memory.pressure >= 2 || swapHeavy {
            let heavy = f.apps.sorted { $0.mem > $1.mem }.prefix(3)
            tips.append(BoostTip(
                id: "mem", level: f.memory.pressure >= 4 ? .bad : .warn, icon: "memorychip",
                title: f.memory.pressure >= 2 ? "Не хватает памяти" : "Mac активно использует подкачку (\(Fmt.bytes(f.memory.swap)))",
                detail: "Когда память кончается, macOS пишет её на диск — всё начинает подтормаживать. Закройте лишние программы и вкладки браузера.",
                apps: heavy.map { BoostApp(id: $0.app.processIdentifier, name: $0.app.localizedName ?? "Программа",
                                          icon: $0.app.icon, value: Fmt.bytes($0.mem)) }))
        } else {
            tips.append(BoostTip(id: "mem", level: .ok, icon: "memorychip", title: "Памяти хватает", detail: ""))
        }

        // Диск.
        if f.diskTotal > 0 {
            let share = f.diskFree / f.diskTotal
            let gb = 1_073_741_824.0
            let level: BoostTip.Level = (share < 0.1 || f.diskFree < 10 * gb) ? .bad : (share < 0.2 || f.diskFree < 20 * gb) ? .warn : .ok
            if level == .ok {
                tips.append(BoostTip(id: "disk", level: .ok, icon: "internaldrive", title: "На диске свободно \(Fmt.bytes(f.diskFree))", detail: ""))
            } else {
                tips.append(BoostTip(
                    id: "disk", level: level, icon: "internaldrive",
                    title: "Мало места: свободно \(Fmt.bytes(f.diskFree))",
                    detail: "macOS нужно 15–20% свободного места для подкачки и обновлений. Удалите ненужное в «Хранилище».",
                    buttonTitle: "Хранилище",
                    action: { openSettings("x-apple.systempreferences:com.apple.settings.Storage") }))
            }
        }

        // Перезагрузка.
        let days = Int(f.uptime / 86_400)
        if days >= 7 {
            tips.append(BoostTip(
                id: "uptime", level: days >= 21 ? .bad : .warn, icon: "arrow.clockwise",
                title: "Mac не перезагружался \(days) дн.",
                detail: "За долгую работу копятся зависшие процессы и «утечки» памяти. Перезагрузка — самый действенный способ ускорить Mac.",
                buttonTitle: "Перезагрузить…",
                action: restart))
        } else {
            tips.append(BoostTip(id: "uptime", level: .ok, icon: "arrow.clockwise",
                                 title: days == 0 ? "Перезагрузка была сегодня" : "Перезагрузка была \(days) дн. назад", detail: ""))
        }

        // Прозрачность и анимации — заметно на графике Intel.
        if intel && !(reduceTransparency && reduceMotion) {
            tips.append(BoostTip(
                id: "visual", level: .warn, icon: "sparkles",
                title: "Прозрачность и анимации интерфейса",
                detail: "На Intel они нагружают графику. В «Универсальный доступ → Дисплей» включите «Уменьшить прозрачность» и «Уменьшить движение».",
                buttonTitle: "Открыть",
                action: { openSettings("x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") }))
        }

        // Фоновые службы.
        if f.backgroundServices >= 6 {
            tips.append(BoostTip(
                id: "login", level: .warn, icon: "list.bullet.rectangle",
                title: "Фоновых служб: \(f.backgroundServices)",
                detail: "Каждая запускается вместе с Mac и отнимает память. Выключите ненужные в «Объектах входа» (раздел «Разрешить в фоне»).",
                buttonTitle: "Объекты входа",
                action: { openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }))
        }

        // Энергосбережение.
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            tips.append(BoostTip(
                id: "lowpower", level: .warn, icon: "battery.25",
                title: "Включён режим энергосбережения",
                detail: "Он нарочно замедляет Mac ради батареи. Выключите, когда нужна скорость.",
                buttonTitle: "Аккумулятор",
                action: { openSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension") }))
        }

        return tips.sorted { $0.level.rawValue < $1.level.rawValue }
    }

    /// Системные процессы, которые иногда грузят Mac, — что это и что делать.
    private static func systemHint(_ name: String) -> (title: String, detail: String)? {
        let n = name.lowercased()
        if n.hasPrefix("mds") || n.hasPrefix("mdworker") {
            return ("Spotlight индексирует диск", "Это временно и проходит само. Если длится днями — исключите большие папки в «Spotlight → Конфиденциальность».")
        }
        if n.contains("photoanalysisd") || n.contains("mediaanalysisd") {
            return ("«Фото» анализирует медиатеку", "Проходит само; быстрее закончится, если оставить Mac на зарядке.")
        }
        if n == "kernel_task" {
            return ("kernel_task охлаждает процессор", "Так macOS сбивает перегрев. Закройте тяжёлые программы и дайте Mac остыть.")
        }
        if n == "windowserver" {
            return ("Графика интерфейса", "Закройте лишние окна, уменьшите прозрачность и движение, отключите второй монитор с высоким разрешением.")
        }
        if n == "backupd" {
            return ("Идёт резервная копия Time Machine", "Проходит само.")
        }
        if n == "softwareupdated" {
            return ("macOS скачивает обновление", "Проходит само.")
        }
        if n == "bird" || n == "cloudd" || n == "fileproviderd" {
            return ("Синхронизация iCloud", "Проходит само; быстрее — на зарядке и хорошем интернете.")
        }
        return nil
    }

    private static func openSettings(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Системный вопрос «Перезагрузить компьютер?» — решает пользователь.
    private static func restart() {
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"])
        }
    }
}

/// Вкладка «Ускорение» в окошке у цифр меню-бара.
struct SysBoostTab: View {
    let openFans: () -> Void
    @ObservedObject private var checkup = MacCheckup.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).font(.system(size: 13, weight: .semibold))
                    Text(checkup.checkedAt.map { "Проверено: \(Fmt.ago($0))" } ?? "Проверяю…")
                        .font(.system(size: 11)).foregroundStyle(MH.t3)
                }
                Spacer()
                if checkup.checking {
                    ProgressView().controlSize(.small)
                } else {
                    MHIconButton("arrow.clockwise", help: "Проверить ещё раз", size: 26) { checkup.run(openFans: openFans) }
                }
            }

            ForEach(checkup.tips.filter { $0.level != .ok }.prefix(4)) { tip in
                BoostTipCard(tip: tip)
            }

            let ok = checkup.tips.filter { $0.level == .ok }
            if !ok.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ok) { tip in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(MH.green).font(.system(size: 12))
                            Text(tip.title).font(.system(size: 12)).foregroundStyle(MH.t2)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }

            HStack(spacing: 8) {
                Image(systemName: "leaf").font(.system(size: 11)).foregroundStyle(prefs.lite ? MH.green : MH.t3)
                Text(prefs.lite ? "Magic Hub в экономном режиме: реже опросы, без анимаций"
                                : "Экономный режим Magic Hub выключен — включается в настройках")
                    .font(.system(size: 11)).foregroundStyle(MH.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if checkup.checkedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true { checkup.run(openFans: openFans) }
        }
    }

    private var summary: String {
        let n = checkup.tips.filter { $0.level != .ok }.count
        if checkup.tips.isEmpty { return "Проверка Mac" }
        if n == 0 { return "Всё в порядке" }
        return "Что замедляет Mac: \(n)"
    }
}

private struct BoostTipCard: View {
    let tip: BoostTip
    @State private var closed: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tip.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(tip.level == .bad ? MH.red : MH.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tip.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MH.t1)
                        .fixedSize(horizontal: false, vertical: true)
                    if !tip.detail.isEmpty {
                        Text(tip.detail).font(.system(size: 11)).foregroundStyle(MH.t2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(tip.apps.filter { !closed.contains($0.id) }) { app in
                HStack(spacing: 8) {
                    Group {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "app").foregroundStyle(MH.t3)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(app.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(app.value).font(.system(size: 11)).foregroundStyle(MH.t3).monospacedDigit()
                    Button("Закрыть") {
                        NSRunningApplication(processIdentifier: app.id)?.terminate()
                        closed.insert(app.id)
                    }
                    .buttonStyle(MHButtonStyle())
                    .controlSize(.small)
                }
                .padding(.leading, 28)
            }
            if let title = tip.buttonTitle, let action = tip.action {
                Button(title, action: action)
                    .buttonStyle(MHButtonStyle(kind: .prominent))
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}
