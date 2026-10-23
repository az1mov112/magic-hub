import SwiftUI
import ServiceManagement

/// Все настройки Magic Hub — прямо в чёлке.
struct SettingsTabView: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                UpdateSettingsSection()
                PermissionsSettingsSection()

                SettingsSection("Общее") {
                    SettingsRow("Запускать при входе в систему", subtitle: loginError, subtitleColor: MH.orange) {
                        MHToggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    }
                    SettingsToggleRow("Показывать значок в меню-баре", subtitle: "Сердечко справа: открыть панель, настройки, выход",
                                      isOn: $prefs.showMenuBarIcon)
                }

                SettingsSection("Чёлка") {
                    SettingsSegmentRow("Открывать панель", options: [(OpenMode.hover, "Наведением"), (OpenMode.click, "Кликом")],
                                       selection: $prefs.openMode)
                    SettingsSegmentRow("Стиль чёлки",
                                       subtitle: "Авто: широкая на Mac без выреза, под вырез — на Mac с вырезом",
                                       options: [(NotchStyle.auto, "Авто"), (NotchStyle.wide, "Широкая"), (NotchStyle.cutout, "Под вырез")],
                                       selection: $prefs.notchStyle)
                    SettingsSegmentRow("Размер панели", subtitle: "Всё содержимое уменьшается пропорционально",
                                       options: [(0.8, "80%"), (0.9, "90%"), (1.0, "100%"), (1.1, "110%")],
                                       selection: Binding(get: { prefs.panelScale }, set: { value in
                                           AppModel.shared.holdOpen(for: 1.5)
                                           prefs.panelScale = value
                                       }))
                    SettingsToggleRow("Живые индикаторы в свёрнутой чёлке", subtitle: "Музыка, занятость Джарвиса, «Не спать»",
                                      isOn: $prefs.liveIndicators)
                    SettingsToggleRow("Показывать на всех дисплеях", isOn: $prefs.allDisplays)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("РАЗДЕЛЫ В ПАНЕЛИ")
                        .font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(MH.t3).padding(.leading, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(Tab.allCases.filter { $0 != .settings }) { tab in
                            HStack(spacing: 8) {
                                Image(systemName: tab.icon).font(.system(size: 12)).foregroundStyle(MH.t3).frame(width: 16)
                                Text(tab.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                MHToggle(isOn: Binding(get: { prefs.isVisible(tab) }, set: { prefs.setVisible(tab, $0) }))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(MH.cardDeep))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MH.line, lineWidth: 1))
                        }
                    }
                }

                HUDSettingsSection()
                MenuBarSettingsSection()
                NotificationsSettingsSection()
                ClipboardSettingsSection()
                CalendarSettingsSection()
                TranslateSettingsSection()
                AwakeSettingsSection()
                AISettingsSection()

                SettingsSection("Magic Hub") {
                    SettingsButtonRow("Данные приложения", subtitle: "Буфер, полка, заметки, заготовки, кэш курсов",
                                      buttonTitle: "Показать в Finder") {
                        AppPaths.reveal(AppPaths.support)
                    }
                    SettingsButtonRow("Версия \(version)", subtitle: "Исходники и обновления — на GitHub",
                                      buttonTitle: "Открыть") {
                        if let url = URL(string: "https://github.com/az1mov112/magic-hub/releases") { NSWorkspace.shared.open(url) }
                    }
                    SettingsButtonRow("Диагностика", subtitle: "Технический отчёт, если что-то работает не так. Без текста переписки и токенов",
                                      buttonTitle: "Скопировать") {
                        Diagnostics.copy()
                    }
                    SettingsButtonRow("Выйти из Magic Hub", buttonTitle: "Выйти", destructive: true) {
                        NSApp.terminate(nil)
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.trailing, 6)
        }
        .rememberScroll("settings")
        .panelMeta("Magic Hub \(version)")
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Не получилось: \(error.localizedDescription). Переместите приложение в «Программы»."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
