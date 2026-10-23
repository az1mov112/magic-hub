import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Настройки «Не спать» и помощника с правами администратора.
struct AwakeSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var helperInstalled = PrivilegedHelper.isInstalled
    @State private var helperMessage: String?

    private let icons = ["moon.zzz.fill", "cup.and.saucer.fill", "eye.fill", "lightbulb.fill", "heart.fill"]
    private let colors = ["orange", "green", "blue", "purple", "pink", "none"]

    var body: some View {
        SettingsSection("Не спать") {
            SettingsSegmentRow("Длительность по умолчанию",
                               options: [(15, "15 мин"), (30, "30 мин"), (60, "1 ч"), (120, "2 ч"), (240, "4 ч"), (480, "8 ч"), (0, "∞")],
                               selection: $prefs.awakeDefaultMinutes)

            SettingsRow("Автоматизация", subtitle: "Включать сам, когда выполнены условия") {
                HStack(spacing: 6) {
                    AwakeChip(title: "Внешний дисплей", icon: "display", isOn: $prefs.autoExternalDisplay)
                    AwakeChip(title: "Питание", icon: "powerplug.fill", isOn: $prefs.autoPower)
                    AwakeChip(title: "Приложения", icon: "app.fill", isOn: $prefs.autoApps)
                }
            }
            SettingsSegmentRow("Условия", subtitle: "Достаточно любого или нужны все выбранные",
                               options: [(false, "Любое"), (true, "Все")],
                               selection: $prefs.autoRequireAll)

            if prefs.autoApps {
                AwakeAppsList(ids: $prefs.autoAppIDs)
            }

            SettingsToggleRow("Приостанавливать, пока Mac заблокирован",
                              subtitle: "После разблокировки оставшееся время продолжится",
                              isOn: $prefs.pauseWhenLocked)
            SettingsToggleRow("Включать при запуске Magic Hub", isOn: $prefs.awakeOnLaunch)
            SettingsToggleRow("Слегка двигать указатель",
                              subtitle: "Раз в минуту — чтобы мессенджеры не ставили «отошёл»",
                              isOn: $prefs.jiggleMouse)

            SettingsRow("Значок в меню-баре", subtitle: "Пока режим активен") {
                HStack(spacing: 4) {
                    ForEach(icons, id: \.self) { name in
                        Button { prefs.awakeIcon = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 13))
                                .foregroundStyle(MH.named(prefs.awakeColor) ?? MH.t1)
                                .frame(width: 32, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(MH.card2))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(prefs.awakeIcon == name ? MH.accent : Color.clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SettingsRow("Цвет значка") {
                HStack(spacing: 6) {
                    ForEach(colors, id: \.self) { c in
                        Button { prefs.awakeColor = c } label: {
                            ZStack {
                                if let color = MH.named(c) {
                                    Circle().fill(color).frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "circle.slash").font(.system(size: 14)).foregroundStyle(MH.t2)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(MH.card2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(prefs.awakeColor == c ? MH.accent : Color.clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            SettingsRow("Помощник администратора",
                        subtitle: helperMessage ?? (helperInstalled
                            ? "Установлен: работа с закрытой крышкой и управление вентиляторами"
                            : "Нужен для работы с закрытой крышкой и управления вентиляторами"),
                        subtitleColor: helperMessage != nil ? MH.orange : (helperInstalled ? MH.green : MH.t3)) {
                if helperInstalled {
                    HStack(spacing: 6) {
                        Button("Переустановить") { install() }.buttonStyle(MHButtonStyle())
                        Button("Удалить") { uninstall() }.buttonStyle(MHButtonStyle(kind: .destructive))
                    }
                } else {
                    Button("Установить") { install() }.buttonStyle(MHButtonStyle(kind: .prominent))
                }
            }
        }
    }

    private func install() {
        let r = PrivilegedHelper.install()
        helperInstalled = PrivilegedHelper.isInstalled
        helperMessage = r.ok ? nil : r.error
        if helperInstalled { AwakeController.shared.helperChanged() }
    }

    private func uninstall() {
        // Перед удалением вернуть Mac обычный сон и вентиляторы в авто.
        AwakeController.shared.shutdownClamshellOnly()
        FanController.shared.restoreAutomatic()
        let r = PrivilegedHelper.uninstall()
        helperInstalled = PrivilegedHelper.isInstalled
        helperMessage = r.ok ? nil : r.error
    }
}

/// Чип-переключатель условия автоматизации.
private struct AwakeChip: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? MH.t1 : MH.t2)
            .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? MH.accent.opacity(0.2) : MH.card2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? MH.accent : MH.control, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Список приложений для автоматизации: «Не спать», пока открыто любое из них.
private struct AwakeAppsList: View {
    @Binding var ids: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 8) {
                    if let icon = AwakeAppsList.icon(for: id) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app").frame(width: 18, height: 18).foregroundStyle(MH.t3)
                    }
                    Text(AwakeAppsList.name(for: id)).font(.system(size: 13))
                    Spacer()
                    Button {
                        ids.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(MH.t3)
                    }
                    .buttonStyle(.plain)
                    .help("Убрать")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            HStack {
                Button {
                    addApps()
                } label: {
                    Label("Добавить приложение…", systemImage: "plus")
                }
                .buttonStyle(MHButtonStyle())
                Spacer()
                Text("Не давать Mac уснуть, пока открыто любое из этих приложений, даже в фоне")
                    .font(.system(size: 11)).foregroundStyle(MH.t3)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    private func addApps() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        var set = ids
        for url in panel.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier, !set.contains(bid) { set.append(bid) }
        }
        ids = set
    }

    static func appURL(for id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(for id: String) -> String {
        guard let url = appURL(for: id) else { return id }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(for id: String) -> NSImage? {
        guard let url = appURL(for: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
