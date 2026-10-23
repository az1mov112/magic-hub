import Foundation
import AppKit

/// Помощник с правами администратора: один на всё — закрытая крышка (pmset) и вентиляторы (SMC).
/// Ставится одним запросом пароля: копия исполняемого файла в /Library/PrivilegedHelperTools
/// и правило sudoers, разрешающее без пароля только эти команды.
enum PrivilegedHelper {
    static let helperPath = "/Library/PrivilegedHelperTools/app.magichub.helper"
    static let sudoersPath = "/etc/sudoers.d/magichub"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath) && FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func install() -> (ok: Bool, error: String) {
        guard let exe = Bundle.main.executableURL?.path else { return (false, "Не найден исполняемый файл приложения") }
        let user = NSUserName()
        guard !user.isEmpty, user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return (false, "Необычное имя пользователя «\(user)» — установка отменена")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, \(helperPath) --smc *"
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(q(exe)) \(helperPath)",
            "chown root:wheel \(helperPath)",
            "chmod 755 \(helperPath)",
            "TMP=$(mktemp /tmp/magichub.sudoers.XXXXXX)",
            "printf '%s\\n' \(q(rule)) > \"$TMP\"",
            "/usr/sbin/visudo -cf \"$TMP\"",
            "chown root:wheel \"$TMP\"",
            "chmod 0440 \"$TMP\"",
            "mv \"$TMP\" \(sudoersPath)"
        ].joined(separator: " && ")
        return Shell.runAsAdmin(cmd)
    }

    static func uninstall() -> (ok: Bool, error: String) {
        Shell.runAsAdmin("rm -f \(sudoersPath) \(helperPath)")
    }

    /// Запуск помощника без пароля (через правило sudoers).
    @discardableResult
    static func smc(_ args: [String]) -> Shell.Result {
        Shell.run("/usr/bin/sudo", ["-n", helperPath, "--smc"] + args)
    }

    @discardableResult
    static func pmsetDisableSleep(_ on: Bool) -> Shell.Result {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    }
}

/// Управление вентиляторами (только на Mac, где они есть). Скорости читает SysMonitor.
final class FanController: ObservableObject {
    static let shared = FanController()

    let hasFans: Bool
    /// Вентиляторы в ручном режиме: № → целевые об/мин.
    @Published private(set) var manualTargets: [Int: Double] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    private let queue = DispatchQueue(label: "app.magichub.fans", qos: .userInitiated)
    private let flagKey = "fans.manualActive"

    private init() {
        hasFans = FanSMC.count(SMCConnection.shared) > 0
    }

    /// Если прошлый запуск оборвался в ручном режиме — вернуть автоматику.
    func recoverIfNeeded() {
        guard UserDefaults.standard.bool(forKey: flagKey), PrivilegedHelper.isInstalled else { return }
        queue.async {
            PrivilegedHelper.smc(["auto"])
            DispatchQueue.main.async { UserDefaults.standard.set(false, forKey: self.flagKey) }
        }
    }

    func isManual(_ index: Int) -> Bool { manualTargets[index] != nil }

    func setManual(_ index: Int, rpm: Double) {
        guard PrivilegedHelper.isInstalled else {
            lastError = "Нужен помощник: «Разрешить» ниже"
            return
        }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let r = PrivilegedHelper.smc(["set", "\(index)", "\(Int(rpm))"])
            DispatchQueue.main.async {
                self.busy = false
                if r.ok {
                    self.manualTargets[index] = rpm
                    self.lastError = nil
                    UserDefaults.standard.set(true, forKey: self.flagKey)
                } else {
                    self.lastError = "Не удалось задать скорость" + (r.err.isEmpty ? "" : ": \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                SysMonitor.shared.refreshNow()
            }
        }
    }

    func setAuto(_ index: Int) {
        guard PrivilegedHelper.isInstalled else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let r = PrivilegedHelper.smc(["auto", "\(index)"])
            DispatchQueue.main.async {
                self.busy = false
                self.manualTargets[index] = nil
                if self.manualTargets.isEmpty { UserDefaults.standard.set(false, forKey: self.flagKey) }
                self.lastError = r.ok ? nil : "Не удалось вернуть авто-режим"
                SysMonitor.shared.refreshNow()
            }
        }
    }

    /// При выходе из приложения: вернуть все вентиляторы в автоматический режим (синхронно).
    func restoreAutomatic() {
        let flagged = UserDefaults.standard.bool(forKey: flagKey)
        guard !manualTargets.isEmpty || flagged, PrivilegedHelper.isInstalled else { return }
        PrivilegedHelper.smc(["auto"])
        manualTargets = [:]
        UserDefaults.standard.set(false, forKey: flagKey)
    }
}
