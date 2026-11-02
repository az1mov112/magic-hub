import AppKit

/// Технический отчёт для разработчика: что видит Magic Hub у Джарвиса и в Notion.
/// Без текста переписки, токенов и содержимого задач; домашняя папка заменена на «~».
enum Diagnostics {
    static func copy() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var arch = "Intel"
        #if arch(arm64)
        arch = "Apple Silicon"
        #endif
        let header = "Magic Hub \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)"
        let notion = NotionService.shared.diagnostics()
        AppModel.shared.flash("Собираю диагностику…")
        DispatchQueue.global(qos: .userInitiated).async {
            let pid = ProcessInfo.processInfo.processIdentifier
            let cpu = Shell.run("/bin/ps", ["-o", "pcpu=,rss=", "-p", "\(pid)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let load = "нагрузка Magic Hub (CPU %, память КБ): \(cpu), в среднем с запуска: \(averageCPU()), экономный режим: \(Prefs.shared.lite ? "да" : "нет")"
            let jarvis = Prefs.shared.jarvisEnabled ? JarvisMonitor.shared.diagnostics() : "[Джарвис]\nмониторинг выключен"
            let notifications = SystemNotificationsMonitor.shared.diagnostics()
            DispatchQueue.main.async {
                Clipboard.copy([header + "\n" + load, jarvis, notion, notifications].joined(separator: "\n\n"))
                AppModel.shared.flash("Диагностика скопирована — вставьте её в чат")
            }
        }
    }

    /// Средняя нагрузка процессора с запуска: «ps» показывает последнюю минуту, а она завышена,
    /// пока открыта панель с настройками, из которой копируют отчёт.
    private static func averageCPU() -> String {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return "?" }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "?" }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let uptime = Date().timeIntervalSince1970 - started
        guard uptime > 1 else { return "?" }
        let minutes = Int(uptime / 60)
        return String(format: "%.1f%%", cpu / uptime * 100) + " за \(minutes / 60) ч \(minutes % 60) мин"
    }
}
