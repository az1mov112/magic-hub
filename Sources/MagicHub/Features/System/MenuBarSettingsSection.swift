import SwiftUI

/// Настройки цифр справа в меню-баре.
struct MenuBarSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        SettingsSection("Цифры в меню-баре") {
            SettingsToggleRow("Нагрузка процессора", isOn: $prefs.mbCPU)
            SettingsToggleRow("Температура процессора", isOn: $prefs.mbCPUTemp)
            SettingsToggleRow("Занятая память", isOn: $prefs.mbRAM)
            SettingsToggleRow("Температура батареи", isOn: $prefs.mbBatteryTemp)
            SettingsToggleRow("Скорость вентилятора",
                              subtitle: FanController.shared.hasFans ? "Управление — в окошке по клику на цифры" : "На этом Mac нет вентилятора",
                              isOn: $prefs.mbFan)
            SettingsSegmentRow("Обновлять каждые",
                               options: [(1.0, "1 с"), (2.0, "2 с"), (5.0, "5 с")],
                               selection: $prefs.mbInterval)
        }
    }
}
