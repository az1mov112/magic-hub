import AppKit
import IOKit
import IOKit.pwr_mgt
import Combine

enum AwakeDuration: Hashable {
    case minutes(Int)
    case indefinite
    case until

    static func fromDefault(_ minutes: Int) -> AwakeDuration { minutes > 0 ? .minutes(minutes) : .indefinite }
}

enum AwakePause: Equatable { case battery, locked }

/// «Не давать Mac уснуть»: запреты сна (IOPMAssertion), закрытая крышка (pmset disablesleep),
/// порог заряда, автоматизация, пауза при блокировке, «шевеление» курсора.
final class AwakeController: ObservableObject {
    static let shared = AwakeController()

    /// Сейчас Mac действительно не уснёт (режим включён и не на паузе).
    @Published private(set) var isActive = false
    /// Режим включён (пользователем или автоматизацией), даже если на паузе.
    @Published private(set) var isEnabled = false
    @Published private(set) var selected: AwakeDuration?
    /// nil — бессрочно.
    @Published private(set) var endDate: Date?
    @Published private(set) var pause: AwakePause?
    @Published private(set) var startedByAutomation = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onAC = true
    @Published private(set) var clamshellError: String?
    /// Время для чипа «До…».
    @Published var untilTime: Date = AwakeController.defaultUntil() {
        didSet {
            if isEnabled && selected == .until {
                endDate = nextUntilDate()
            }
        }
    }

    private var sysAssertion: IOPMAssertionID = 0
    private var dispAssertion: IOPMAssertionID = 0
    private var remainingWhenPaused: TimeInterval?
    private var automationSuppressed = false
    private var timer: Timer?
    private var lastJiggle = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private let pmsetQueue = DispatchQueue(label: "app.magichub.pmset")
    private let disableSleepFlag = "awake.disableSleepSetByUs"

    private init() {}

    // MARK: Жизненный цикл

    func start() {
        guard !started else { return }
        started = true

        // Если прошлый запуск оборвался, а disablesleep остался включённым — вернуть сон.
        if UserDefaults.standard.bool(forKey: disableSleepFlag) {
            UserDefaults.standard.set(false, forKey: disableSleepFlag)
            pmsetQueue.async { PrivilegedHelper.pmsetDisableSleep(false) }
        }

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked()
        })
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenUnlocked()
        })

        let p = Prefs.shared
        p.$clamshell.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyState() } }
            .store(in: &cancellables)
        p.$allowDisplaySleep.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyState() } }
            .store(in: &cancellables)
        p.$batteryThreshold.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.tick() } }
            .store(in: &cancellables)

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refreshPower()
        if p.awakeOnLaunch {
            activate(.fromDefault(p.awakeDefaultMinutes))
        }
        tick()
    }

    /// При выходе из приложения — вернуть Mac обычный сон.
    func shutdown() {
        timer?.invalidate()
        releaseAssertions()
        if UserDefaults.standard.bool(forKey: disableSleepFlag) {
            PrivilegedHelper.pmsetDisableSleep(false)
            UserDefaults.standard.set(false, forKey: disableSleepFlag)
        }
    }

    // MARK: Управление

    func toggle() {
        if isEnabled { deactivate() } else { activate(.fromDefault(Prefs.shared.awakeDefaultMinutes)) }
    }

    /// Нажатие на чип длительности: повторное нажатие на активный — выключить.
    func chipTapped(_ d: AwakeDuration) {
        if isEnabled && selected == d { deactivate() } else { activate(d) }
    }

    func activate(_ d: AwakeDuration, byAutomation: Bool = false) {
        selected = d
        isEnabled = true
        startedByAutomation = byAutomation
        remainingWhenPaused = nil
        switch d {
        case .indefinite: endDate = nil
        case .minutes(let m): endDate = Date().addingTimeInterval(TimeInterval(m * 60))
        case .until: endDate = nextUntilDate()
        }
        if pause == .battery { pause = nil }
        evaluateBattery(notify: false)
        applyState()
    }

    func deactivate(byUser: Bool = true) {
        if byUser && automationConditionsMet() { automationSuppressed = true }
        isEnabled = false
        selected = nil
        endDate = nil
        pause = nil
        startedByAutomation = false
        remainingWhenPaused = nil
        applyState()
    }

    var statusText: String {
        if !isEnabled { return "Mac следует обычным правилам энергосбережения" }
        switch pause {
        case .battery:
            return "На паузе: заряд \(batteryPercent ?? 0)% ниже порога \(Prefs.shared.batteryThreshold)%"
        case .locked:
            return "На паузе, пока Mac заблокирован"
        case nil:
            break
        }
        guard let end = endDate else {
            return startedByAutomation ? "Активно по автоматизации" : "Активно, пока вы не отключите режим"
        }
        if selected == .until {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Активно до \(f.string(from: end))"
        }
        return "Активно ещё \(Fmt.duration(end.timeIntervalSinceNow))"
    }

    func untilLabel() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "До \(f.string(from: untilTime))"
    }

    // MARK: Внутреннее

    private static func defaultUntil() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 18
        comps.minute = 0
        return cal.date(from: comps) ?? Date().addingTimeInterval(3600)
    }

    private func nextUntilDate() -> Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: untilTime)
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hm.hour
        comps.minute = hm.minute
        var d = cal.date(from: comps) ?? Date().addingTimeInterval(3600)
        if d <= Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400) }
        return d
    }

    private func tick() {
        refreshPower()
        // Срок вышел.
        if isEnabled, pause == nil, let end = endDate, Date() >= end {
            deactivate(byUser: false)
        }
        evaluateBattery(notify: true)
        evaluateAutomation()
        jiggleIfNeeded()
    }

    private func refreshPower() {
        if let b = SysPower.read(includeDetails: false) {
            batteryPercent = b.percent
            onAC = b.onAC || b.isCharging
        } else {
            batteryPercent = nil
            onAC = SysPower.isOnAC()
        }
    }

    private func evaluateBattery(notify: Bool) {
        guard isEnabled else { return }
        let threshold = Prefs.shared.batteryThreshold
        let low = !onAC && (batteryPercent ?? 100) < threshold
        if low && pause != .battery {
            if pause == nil, let end = endDate { remainingWhenPaused = end.timeIntervalSinceNow }
            pause = .battery
            applyState()
            if notify {
                AppModel.shared.post(NotchNotification(title: "«Не спать» на паузе",
                                                       subtitle: "Заряд \(batteryPercent ?? 0)% ниже порога \(threshold)%",
                                                       kind: .warning,
                                                       icon: "battery.25"))
            }
        } else if !low && pause == .battery {
            if let rem = remainingWhenPaused { endDate = Date().addingTimeInterval(max(0, rem)) }
            remainingWhenPaused = nil
            pause = nil
            applyState()
        }
    }

    private func automationConditionsMet() -> Bool {
        let p = Prefs.shared
        var conds: [Bool] = []
        if p.autoExternalDisplay { conds.append(AwakeController.hasExternalDisplay()) }
        if p.autoPower { conds.append(onAC) }
        if p.autoApps {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            conds.append(p.autoAppIDs.contains { running.contains($0) })
        }
        guard !conds.isEmpty else { return false }
        return p.autoRequireAll ? conds.allSatisfy { $0 } : conds.contains(true)
    }

    private func evaluateAutomation() {
        let p = Prefs.shared
        let anyCondition = p.autoExternalDisplay || p.autoPower || p.autoApps
        guard anyCondition else {
            automationSuppressed = false
            return
        }
        let met = automationConditionsMet()
        if !met { automationSuppressed = false }
        if met && !isEnabled && !automationSuppressed {
            activate(.indefinite, byAutomation: true)
        } else if !met && isEnabled && startedByAutomation {
            deactivate(byUser: false)
        }
    }

    static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func jiggleIfNeeded() {
        guard isActive, Prefs.shared.jiggleMouse, Date().timeIntervalSince(lastJiggle) >= 60 else { return }
        lastJiggle = Date()
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Magic Hub" as CFString, kIOPMUserActiveLocal, &activity)
        // Сдвинуть курсор на 1 px и вернуть (координаты CG: начало — левый верхний угол основного экрана).
        let loc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: loc.x, y: primaryHeight - loc.y)
        CGWarpMouseCursorPosition(CGPoint(x: p.x + 1, y: p.y))
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func applyState() {
        let hold = isEnabled && pause == nil
        if hold { acquireAssertions() } else { releaseAssertions() }
        if isActive != hold { isActive = hold }
        applyClamshell(hold && Prefs.shared.clamshell)
    }

    private func acquireAssertions() {
        if sysAssertion == 0 {
            _ = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                            IOPMAssertionLevel(255),
                                            "Magic Hub: не давать Mac уснуть" as CFString,
                                            &sysAssertion)
        }
        let wantDisplay = !Prefs.shared.allowDisplaySleep
        if wantDisplay && dispAssertion == 0 {
            _ = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                            IOPMAssertionLevel(255),
                                            "Magic Hub: не гасить экран" as CFString,
                                            &dispAssertion)
        } else if !wantDisplay && dispAssertion != 0 {
            IOPMAssertionRelease(dispAssertion)
            dispAssertion = 0
        }
    }

    private func releaseAssertions() {
        if sysAssertion != 0 {
            IOPMAssertionRelease(sysAssertion)
            sysAssertion = 0
        }
        if dispAssertion != 0 {
            IOPMAssertionRelease(dispAssertion)
            dispAssertion = 0
        }
    }

    /// Закрытая крышка: `pmset -a disablesleep 1` через помощника, пока режим активен.
    private func applyClamshell(_ on: Bool) {
        let setByUs = UserDefaults.standard.bool(forKey: disableSleepFlag)
        if on && !setByUs {
            guard PrivilegedHelper.isInstalled else {
                clamshellError = "Нужен помощник: нажмите «Разрешить»"
                return
            }
            UserDefaults.standard.set(true, forKey: disableSleepFlag)
            pmsetQueue.async { [weak self] in
                let r = PrivilegedHelper.pmsetDisableSleep(true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if r.ok {
                        self.clamshellError = nil
                    } else {
                        UserDefaults.standard.set(false, forKey: self.disableSleepFlag)
                        self.clamshellError = "Не удалось отключить сон с закрытой крышкой"
                    }
                }
            }
        } else if !on && setByUs {
            UserDefaults.standard.set(false, forKey: disableSleepFlag)
            clamshellError = nil
            pmsetQueue.async { PrivilegedHelper.pmsetDisableSleep(false) }
        } else if !on {
            clamshellError = nil
        }
    }

    /// После установки помощника — применить текущее состояние.
    func helperChanged() { applyState() }

    /// Вернуть обычный сон с закрытой крышкой (перед удалением помощника). Сам режим не трогаем.
    func shutdownClamshellOnly() {
        if UserDefaults.standard.bool(forKey: disableSleepFlag) {
            PrivilegedHelper.pmsetDisableSleep(false)
            UserDefaults.standard.set(false, forKey: disableSleepFlag)
        }
    }

    private func screenLocked() {
        DispatchQueue.main.async {
            guard Prefs.shared.pauseWhenLocked, self.isEnabled, self.pause == nil else { return }
            if let end = self.endDate { self.remainingWhenPaused = end.timeIntervalSinceNow }
            self.pause = .locked
            self.applyState()
        }
    }

    private func screenUnlocked() {
        DispatchQueue.main.async {
            guard self.pause == .locked else { return }
            if let rem = self.remainingWhenPaused { self.endDate = Date().addingTimeInterval(max(0, rem)) }
            self.remainingWhenPaused = nil
            self.pause = nil
            self.evaluateBattery(notify: true)
            self.applyState()
        }
    }
}
