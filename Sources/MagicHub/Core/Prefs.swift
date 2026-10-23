import Foundation
import Combine

enum OpenMode: String, CaseIterable { case hover, click }
enum NotchStyle: String, CaseIterable { case auto, wide, cutout }
enum AutoClean: String, CaseIterable { case off, days7, days30, count500 }
enum CalendarSource: String, CaseIterable { case notion, mac }
enum TranslateEngine: String, CaseIterable { case google, apple }

/// Все настройки приложения. Хранятся в UserDefaults, меняются из любых экранов.
/// Секреты (токены) здесь не хранятся — только в Связке ключей (см. `Keychain`).
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let d = UserDefaults.standard

    // MARK: Общее
    @Published var showMenuBarIcon: Bool = Prefs.bool("showMenuBarIcon", true) { didSet { Prefs.d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    @Published var autoUpdateCheck: Bool = Prefs.bool("autoUpdateCheck", true) { didSet { Prefs.d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }

    /// Свои индикаторы громкости и яркости в чёлке вместо системных.
    @Published var customHUD: Bool = Prefs.bool("customHUD", true) { didSet { Prefs.d.set(customHUD, forKey: "customHUD") } }

    // MARK: Чёлка
    @Published var openMode: OpenMode = Prefs.enumValue("openMode", OpenMode.hover) { didSet { Prefs.d.set(openMode.rawValue, forKey: "openMode") } }
    @Published var notchStyle: NotchStyle = Prefs.enumValue("notchStyle", NotchStyle.auto) { didSet { Prefs.d.set(notchStyle.rawValue, forKey: "notchStyle") } }
    @Published var liveIndicators: Bool = Prefs.bool("liveIndicators", true) { didSet { Prefs.d.set(liveIndicators, forKey: "liveIndicators") } }
    @Published var allDisplays: Bool = Prefs.bool("allDisplays", false) { didSet { Prefs.d.set(allDisplays, forKey: "allDisplays") } }
    /// Размер раскрытой панели: 0,8 / 0,9 / 1,0 / 1,1.
    @Published var panelScale: Double = Prefs.double("panelScale", 1.0) { didSet { Prefs.d.set(panelScale, forKey: "panelScale") } }
    @Published var hiddenTabs: [String] = Prefs.strings("hiddenTabs") { didSet { Prefs.d.set(hiddenTabs, forKey: "hiddenTabs") } }

    // MARK: Цифры в меню-баре
    @Published var mbCPU: Bool = Prefs.bool("mbCPU", true) { didSet { Prefs.d.set(mbCPU, forKey: "mbCPU") } }
    @Published var mbCPUTemp: Bool = Prefs.bool("mbCPUTemp", true) { didSet { Prefs.d.set(mbCPUTemp, forKey: "mbCPUTemp") } }
    @Published var mbRAM: Bool = Prefs.bool("mbRAM", true) { didSet { Prefs.d.set(mbRAM, forKey: "mbRAM") } }
    @Published var mbBatteryTemp: Bool = Prefs.bool("mbBatteryTemp", true) { didSet { Prefs.d.set(mbBatteryTemp, forKey: "mbBatteryTemp") } }
    @Published var mbFan: Bool = Prefs.bool("mbFan", false) { didSet { Prefs.d.set(mbFan, forKey: "mbFan") } }
    @Published var mbInterval: Double = Prefs.double("mbInterval", 2) { didSet { Prefs.d.set(mbInterval, forKey: "mbInterval") } }

    // MARK: Уведомления в чёлке
    @Published var evTaskTaken: Bool = Prefs.bool("evTaskTaken", true) { didSet { Prefs.d.set(evTaskTaken, forKey: "evTaskTaken") } }
    @Published var evTaskDone: Bool = Prefs.bool("evTaskDone", true) { didSet { Prefs.d.set(evTaskDone, forKey: "evTaskDone") } }
    @Published var evError: Bool = Prefs.bool("evError", true) { didSet { Prefs.d.set(evError, forKey: "evError") } }
    @Published var evHang: Bool = Prefs.bool("evHang", true) { didSet { Prefs.d.set(evHang, forKey: "evHang") } }
    @Published var evRestart: Bool = Prefs.bool("evRestart", true) { didSet { Prefs.d.set(evRestart, forKey: "evRestart") } }

    // MARK: Буфер и полка
    @Published var saveClipboardImages: Bool = Prefs.bool("saveClipboardImages", true) { didSet { Prefs.d.set(saveClipboardImages, forKey: "saveClipboardImages") } }
    @Published var watchScreenshotFolder: Bool = Prefs.bool("watchScreenshotFolder", false) { didSet { Prefs.d.set(watchScreenshotFolder, forKey: "watchScreenshotFolder") } }
    @Published var autoClean: AutoClean = Prefs.enumValue("autoClean", AutoClean.off) { didSet { Prefs.d.set(autoClean.rawValue, forKey: "autoClean") } }

    // MARK: Календарь
    @Published var calendarSource: CalendarSource = Prefs.enumValue("calendarSource", CalendarSource.notion) { didSet { Prefs.d.set(calendarSource.rawValue, forKey: "calendarSource") } }
    /// Ссылка на базу задач Notion или её ID. Токен Notion — в Связке ключей.
    @Published var notionDatabase: String = Prefs.string("notionDatabase", "") { didSet { Prefs.d.set(notionDatabase, forKey: "notionDatabase") } }

    // MARK: Перевод
    @Published var translateEngine: TranslateEngine = Prefs.enumValue("translateEngine", TranslateEngine.google) { didSet { Prefs.d.set(translateEngine.rawValue, forKey: "translateEngine") } }
    @Published var translateFrom: String = Prefs.string("translateFrom", "en") { didSet { Prefs.d.set(translateFrom, forKey: "translateFrom") } }
    @Published var translateTo: String = Prefs.string("translateTo", "ru") { didSet { Prefs.d.set(translateTo, forKey: "translateTo") } }

    // MARK: Не спать
    /// 0 = бессрочно.
    @Published var awakeDefaultMinutes: Int = Prefs.int("awakeDefaultMinutes", 0) { didSet { Prefs.d.set(awakeDefaultMinutes, forKey: "awakeDefaultMinutes") } }
    @Published var clamshell: Bool = Prefs.bool("clamshell", false) { didSet { Prefs.d.set(clamshell, forKey: "clamshell") } }
    @Published var allowDisplaySleep: Bool = Prefs.bool("allowDisplaySleep", true) { didSet { Prefs.d.set(allowDisplaySleep, forKey: "allowDisplaySleep") } }
    /// Ниже этого заряда (на батарее) режим «не спать» приостанавливается.
    @Published var batteryThreshold: Int = Prefs.int("batteryThreshold", 20) { didSet { Prefs.d.set(batteryThreshold, forKey: "batteryThreshold") } }
    @Published var autoExternalDisplay: Bool = Prefs.bool("autoExternalDisplay", false) { didSet { Prefs.d.set(autoExternalDisplay, forKey: "autoExternalDisplay") } }
    @Published var autoPower: Bool = Prefs.bool("autoPower", false) { didSet { Prefs.d.set(autoPower, forKey: "autoPower") } }
    @Published var autoApps: Bool = Prefs.bool("autoApps", false) { didSet { Prefs.d.set(autoApps, forKey: "autoApps") } }
    @Published var autoRequireAll: Bool = Prefs.bool("autoRequireAll", true) { didSet { Prefs.d.set(autoRequireAll, forKey: "autoRequireAll") } }
    @Published var autoAppIDs: [String] = Prefs.strings("autoAppIDs") { didSet { Prefs.d.set(autoAppIDs, forKey: "autoAppIDs") } }
    @Published var pauseWhenLocked: Bool = Prefs.bool("pauseWhenLocked", false) { didSet { Prefs.d.set(pauseWhenLocked, forKey: "pauseWhenLocked") } }
    @Published var awakeOnLaunch: Bool = Prefs.bool("awakeOnLaunch", false) { didSet { Prefs.d.set(awakeOnLaunch, forKey: "awakeOnLaunch") } }
    @Published var jiggleMouse: Bool = Prefs.bool("jiggleMouse", false) { didSet { Prefs.d.set(jiggleMouse, forKey: "jiggleMouse") } }
    /// SF Symbol значка в меню-баре, пока режим активен.
    @Published var awakeIcon: String = Prefs.string("awakeIcon", "moon.zzz.fill") { didSet { Prefs.d.set(awakeIcon, forKey: "awakeIcon") } }
    /// Цвет значка: orange, green, blue, purple, pink, none.
    @Published var awakeColor: String = Prefs.string("awakeColor", "pink") { didSet { Prefs.d.set(awakeColor, forKey: "awakeColor") } }

    // MARK: ИИ-агенты и Джарвис
    @Published var jarvisEnabled: Bool = Prefs.bool("jarvisEnabled", true) { didSet { Prefs.d.set(jarvisEnabled, forKey: "jarvisEnabled") } }
    /// Пусто = найти автоматически.
    @Published var jarvisBotDir: String = Prefs.string("jarvisBotDir", "") { didSet { Prefs.d.set(jarvisBotDir, forKey: "jarvisBotDir") } }
    /// Пусто = найти автоматически среди ~/Library/LaunchAgents.
    @Published var jarvisLabel: String = Prefs.string("jarvisLabel", "") { didSet { Prefs.d.set(jarvisLabel, forKey: "jarvisLabel") } }
    @Published var jarvisHome: String = Prefs.string("jarvisHome", "~/.jarvis") { didSet { Prefs.d.set(jarvisHome, forKey: "jarvisHome") } }
    @Published var claudeLimits: Bool = Prefs.bool("claudeLimits", true) { didSet { Prefs.d.set(claudeLimits, forKey: "claudeLimits") } }
    @Published var claudeCost: Bool = Prefs.bool("claudeCost", true) { didSet { Prefs.d.set(claudeCost, forKey: "claudeCost") } }
    @Published var aiInterval: Double = Prefs.double("aiInterval", 10) { didSet { Prefs.d.set(aiInterval, forKey: "aiInterval") } }

    // MARK: Телесуфлёр
    @Published var tpText: String = Prefs.string("tpText", "Привет! Это телесуфлёр Magic Hub.\nТекст плывёт прямо под камерой: смотришь в объектив и читаешь.\nНажми карандаш, чтобы вставить свой сценарий.") { didSet { Prefs.d.set(tpText, forKey: "tpText") } }
    @Published var tpSpeed: Double = Prefs.double("tpSpeed", 1.0) { didSet { Prefs.d.set(tpSpeed, forKey: "tpSpeed") } }
    @Published var tpFontSize: Double = Prefs.double("tpFontSize", 30) { didSet { Prefs.d.set(tpFontSize, forKey: "tpFontSize") } }

    // MARK: Валюта
    @Published var currencyFrom: String = Prefs.string("currencyFrom", "USD") { didSet { Prefs.d.set(currencyFrom, forKey: "currencyFrom") } }
    @Published var currencyTo: String = Prefs.string("currencyTo", "RUB") { didSet { Prefs.d.set(currencyTo, forKey: "currencyTo") } }

    // MARK: Вкладки
    func isVisible(_ tab: Tab) -> Bool { tab == .settings || !hiddenTabs.contains(tab.rawValue) }

    func setVisible(_ tab: Tab, _ visible: Bool) {
        var s = Set(hiddenTabs)
        if visible { s.remove(tab.rawValue) } else { s.insert(tab.rawValue) }
        hiddenTabs = Array(s).sorted()
    }

    // MARK: Чтение из UserDefaults
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func string(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
    static func strings(_ k: String) -> [String] { d.stringArray(forKey: k) ?? [] }
    static func enumValue<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
        T(rawValue: d.string(forKey: k) ?? "") ?? def
    }
}
