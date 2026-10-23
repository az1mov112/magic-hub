import AppKit
import Security

/// Папки приложения: ~/Library/Application Support/MagicHub/…
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("MagicHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func dir(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// Сохранение небольших данных в JSON-файлы в папке приложения.
enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = AppPaths.file(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: AppPaths.file(name), options: .atomic)
    }
}

/// Запуск системных команд. Пути — абсолютные (`/bin/launchctl`, `/usr/bin/pmset`…).
enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String] = [], env: [String: String] = [:]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    static func runAsync(_ path: String, _ args: [String] = [], env: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: run(path, args, env: env))
            }
        }
    }

    /// Команда с правами администратора: macOS сама спросит пароль.
    static func runAsAdmin(_ command: String) -> (ok: Bool, error: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return (false, (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Не удалось выполнить")
        }
        return (true, "")
    }
}

/// Секреты (токены) — только в Связке ключей macOS.
enum Keychain {
    static let service = "app.magichub.MagicHub"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Запись в буфер обмена из самого приложения. Запоминает номер изменения,
/// чтобы история буфера не сохраняла копию повторно (см. ClipboardWatcher).
enum Clipboard {
    static var ownChangeCount: Int = -1

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownChangeCount = pb.changeCount
    }

    static func copy(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        ownChangeCount = pb.changeCount
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        if let image = NSImage(contentsOf: fileURL) { pb.writeObjects([image]) }
        ownChangeCount = pb.changeCount
    }
}

// MARK: - Форматирование

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    /// 3 ч 12 мин / 4 мин / 38 с
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s) с" }
        let m = s / 60
        if m < 60 { return "\(m) мин" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) ч" : "\(h) ч \(m % 60) мин" }
        let d = h / 24
        return h % 24 == 0 ? "\(d) д" : "\(d) д \(h % 24) ч"
    }

    /// 1:42 / 1:02:05
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 12,5 / 1 234,56
    static func number(_ v: Double, maxFraction: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = ru
        f.numberStyle = .decimal
        f.maximumFractionDigits = maxFraction
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// 862 МБ / 2,15 ГБ
    static func bytes(_ v: Double) -> String {
        if v >= 1_073_741_824 { return number(v / 1_073_741_824, maxFraction: 2) + " ГБ" }
        if v >= 1_048_576 { return number(v / 1_048_576, maxFraction: 0) + " МБ" }
        if v >= 1024 { return number(v / 1024, maxFraction: 0) + " КБ" }
        return number(v, maxFraction: 0) + " Б"
    }

    /// 1,2 млн / 64 тыс.
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000 { return number(v / 1_000_000, maxFraction: 1) + " млн" }
        if v >= 1000 { return number(v / 1000, maxFraction: 0) + " тыс." }
        return number(v, maxFraction: 0)
    }

    static func usd(_ v: Double) -> String { "$" + number(v, maxFraction: v < 100 ? 2 : 0) }

    /// «сейчас», «5 мин», «2 ч», «вчера», «12 окт.»
    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 45 { return "сейчас" }
        if s < 3600 { return "\(Int(s / 60)) мин" }
        if Calendar.current.isDateInToday(date) { return "\(Int(s / 3600)) ч" }
        if Calendar.current.isDateInYesterday(date) { return "вчера" }
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
