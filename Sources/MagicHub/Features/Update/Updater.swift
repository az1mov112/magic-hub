import AppKit
import SwiftUI
import Combine

/// Обновления: проверяет свежую сборку в GitHub Releases (тег nightly), показывает уведомление
/// и по кнопке скачивает новую версию, заменяет приложение и перезапускает его.
final class Updater: ObservableObject {
    struct UpdateInfo: Equatable {
        let build: Int
        let version: String
        let url: URL
    }

    static let shared = Updater()
    static let repo = "az1mov112/magic-hub"

    @Published private(set) var available: UpdateInfo?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if Prefs.shared.autoUpdateCheck { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            if Prefs.shared.autoUpdateCheck { self?.check() }
        }
    }

    func check(manual: Bool = false) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/tags/nightly") else { return }
        if manual { status = "Проверяю…" }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.lastCheck = Date()
                    if manual {
                        switch code {
                        case 0: self.status = "Нет связи с GitHub"
                        case 404: self.status = "Новая версия как раз публикуется — проверьте через минуту"
                        case 403, 429: self.status = "GitHub просит подождать — проверьте позже"
                        default: self.status = "GitHub ответил кодом \(code)"
                        }
                    }
                }
                return
            }
            let info = Self.parse(obj)
            DispatchQueue.main.async {
                self.lastCheck = Date()
                guard let info, info.build > self.currentBuild else {
                    self.available = nil
                    if manual { self.status = "У вас последняя версия" }
                    return
                }
                let isNew = self.available?.build != info.build
                self.available = info
                if manual { self.status = nil }
                let notified = UserDefaults.standard.integer(forKey: "updateNotifiedBuild")
                if isNew && notified != info.build {
                    UserDefaults.standard.set(info.build, forKey: "updateNotifiedBuild")
                    AppModel.shared.post(NotchNotification(
                        title: "Доступна новая версия \(info.version)",
                        subtitle: "Нажмите, чтобы обновить Magic Hub",
                        kind: .info,
                        icon: "arrow.down.circle",
                        onTap: { Updater.shared.install() }))
                }
            }
        }.resume()
    }

    /// Номер сборки — из строки «build: N» в описании релиза (или из «0.1.N» в названии).
    private static func parse(_ obj: [String: Any]) -> UpdateInfo? {
        let body = obj["body"] as? String ?? ""
        let name = obj["name"] as? String ?? ""
        var build: Int?
        if let r = body.range(of: #"build:\s*(\d+)"#, options: .regularExpression) {
            build = Int(body[r].filter(\.isNumber))
        }
        if build == nil, let r = name.range(of: #"\d+\.\d+\.(\d+)"#, options: .regularExpression) {
            build = Int(name[r].split(separator: ".").last ?? "")
        }
        guard let build else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let link = zip["browser_download_url"] as? String, let url = URL(string: link) else { return nil }
        return UpdateInfo(build: build, version: "0.1.\(build)", url: url)
    }

    // MARK: - Установка

    func install() {
        guard let info = available, !busy else { return }
        busy = true
        status = "Скачиваю…"
        URLSession.shared.downloadTask(with: info.url) { [weak self] tmp, resp, error in
            guard let self else { return }
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                self.fail("Не удалось скачать: \(error?.localizedDescription ?? "ошибка сети")")
                return
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("MagicHubUpdate-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("MagicHub.zip")
                try fm.moveItem(at: tmp, to: zip)
                DispatchQueue.main.async { self.status = "Распаковываю…" }
                let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                guard unzip.ok else { throw UpdateError("Архив повреждён") }
                let newApp = work.appendingPathComponent("Magic Hub.app")
                guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/MagicHub").path) else {
                    throw UpdateError("В архиве нет приложения")
                }
                Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
                DispatchQueue.main.async { self.replaceAndRelaunch(with: newApp, work: work) }
            } catch {
                self.fail((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }.resume()
    }

    private func replaceAndRelaunch(with newApp: URL, work: URL) {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            fail("Magic Hub запущен не из .app — обновите вручную")
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            return
        }
        status = "Устанавливаю…"
        let backup = work.appendingPathComponent("old.app")
        do {
            // Запущенное приложение можно переместить: процесс продолжает работать из старой копии.
            try fm.moveItem(at: current, to: backup)
            do {
                try fm.moveItem(at: newApp, to: current)
            } catch {
                try? fm.moveItem(at: backup, to: current)
                throw error
            }
        } catch {
            fail("Не удалось заменить приложение: \(error.localizedDescription). Новая версия открыта в Finder — перетащите её в «Программы».")
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            return
        }
        status = "Перезапускаю…"
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = current.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open '\(path)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
        } catch {
            fail("Обновлено. Запустите Magic Hub заново вручную.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.busy = false
            self.status = message
        }
    }

    private struct UpdateError: Error {
        let message: String
        init(_ m: String) { message = m }
    }
}

/// Секция «Обновления» на экране настроек.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        SettingsSection("Обновления") {
            if let info = updater.available {
                SettingsRow("Доступна версия \(info.version)", subtitle: updater.status ?? "Скачать, заменить и перезапустить автоматически",
                            subtitleColor: MH.t3) {
                    Button(updater.busy ? "Обновляю…" : "Обновить") { updater.install() }
                        .buttonStyle(MHButtonStyle(kind: .prominent))
                        .disabled(updater.busy)
                }
            } else {
                SettingsRow("Установлена версия \(updater.currentVersion)", subtitle: subtitle) {
                    Button("Проверить") { updater.check(manual: true) }
                        .buttonStyle(MHButtonStyle())
                }
            }
            SettingsToggleRow("Проверять обновления автоматически", subtitle: "Раз в 30 минут; о новой версии сообщит чёлка",
                              isOn: $prefs.autoUpdateCheck)
        }
    }

    private var subtitle: String {
        if let s = updater.status { return s }
        if let d = updater.lastCheck { return "Проверено: \(Fmt.ago(d))" }
        return "Ещё не проверялось"
    }
}
