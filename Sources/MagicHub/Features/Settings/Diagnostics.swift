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
            let jarvis = Prefs.shared.jarvisEnabled ? JarvisMonitor.shared.diagnostics() : "[Джарвис]\nмониторинг выключен"
            DispatchQueue.main.async {
                Clipboard.copy([header, jarvis, notion].joined(separator: "\n\n"))
                AppModel.shared.flash("Диагностика скопирована — вставьте её в чат")
            }
        }
    }
}
