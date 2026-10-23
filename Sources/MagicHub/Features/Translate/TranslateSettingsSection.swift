import SwiftUI
import AppKit

struct TranslateSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        SettingsSection("Перевод") {
            SettingsSegmentRow("Переводчик",
                               subtitle: "Google — лучшее качество, нужен интернет. Apple — без интернета, языки скачиваются в настройках macOS.",
                               options: [(TranslateEngine.google, "Google"), (TranslateEngine.apple, "Apple")],
                               selection: $prefs.translateEngine)
            SettingsButtonRow("Языки для перевода Apple",
                              subtitle: "Системные настройки → Основные → Язык и регион → Языки перевода",
                              buttonTitle: "Открыть") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
