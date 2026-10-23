import Foundation
import IOKit

// Доступ к SMC (контроллер управления системой): температуры на Intel, вентиляторы на всех Mac.
// Чтение работает от обычного пользователя, запись (вентиляторы) — только от root через помощника.

/// Структура обмена с AppleSMC. Раскладка в памяти должна совпадать с C-версией (80 байт),
/// поэтому после keyInfo стоит явный padding — как в smcFanControl / Stats.
struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCConnection {
    static let shared = SMCConnection()

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    private let selectorHandleYPC: UInt32 = 2
    private let cmdReadKey: UInt8 = 5
    private let cmdWriteKey: UInt8 = 6
    private let cmdGetKeyInfo: UInt8 = 9

    var isOpen: Bool { conn != 0 }

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        if IOServiceOpen(service, mach_task_self_, 0, &c) == kIOReturnSuccess {
            conn = c
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    static func typeString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        guard conn != 0 else { return nil }
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, selectorHandleYPC, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard r == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfoLocked(_ key: UInt32) -> SMCKeyData.KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = key
        input.data8 = cmdGetKeyInfo
        guard let out = call(&input), out.keyInfo.dataSize > 0 else { return nil }
        infoCache[key] = out.keyInfo
        return out.keyInfo
    }

    func hasKey(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keyInfoLocked(SMCConnection.fourCC(key)) != nil
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        lock.lock(); defer { lock.unlock() }
        let k = SMCConnection.fourCC(key)
        guard let info = keyInfoLocked(k) else { return nil }
        var input = SMCKeyData()
        input.key = k
        input.keyInfo.dataSize = info.dataSize
        input.data8 = cmdReadKey
        guard let out = call(&input) else { return nil }
        let size = min(Int(info.dataSize), 32)
        let bytes: [UInt8] = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return (SMCConnection.typeString(info.dataType), bytes)
    }

    func readDouble(_ key: String) -> Double? {
        guard let r = read(key) else { return nil }
        return SMCConnection.decode(type: r.type, bytes: r.bytes)
    }

    func write(_ key: String, bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = SMCConnection.fourCC(key)
        guard let info = keyInfoLocked(k) else { return false }
        var input = SMCKeyData()
        input.key = k
        input.keyInfo.dataSize = info.dataSize
        input.data8 = cmdWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for i in 0..<min(bytes.count, 32, Int(info.dataSize)) { buf[i] = bytes[i] }
        }
        return call(&input) != nil
    }

    func write(_ key: String, value: Double) -> Bool {
        lock.lock()
        let info = keyInfoLocked(SMCConnection.fourCC(key))
        lock.unlock()
        guard let info, let bytes = SMCConnection.encode(type: SMCConnection.typeString(info.dataType), value: value, size: Int(info.dataSize)) else {
            return false
        }
        return write(key, bytes: bytes)
    }

    static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let u = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: u))
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))) / 256
        case "fp88":
            guard b.count >= 2 else { return nil }
            return Double((UInt16(b[0]) << 8) | UInt16(b[1])) / 256
        case "ui8 ", "flag":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        case "si8 ":
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1])))
        case "ui32":
            guard b.count >= 4 else { return nil }
            let u = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            return Double(u)
        default:
            return nil
        }
    }

    static func encode(type: String, value: Double, size: Int) -> [UInt8]? {
        switch type {
        case "flt ":
            let u = Float(value).bitPattern
            return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 24) & 0xFF)]
        case "fpe2":
            let v = UInt16(clamping: Int(max(0, value) * 4))
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        case "ui8 ", "flag":
            return [UInt8(clamping: Int(value))]
        case "ui16":
            let v = UInt16(clamping: Int(value))
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        default:
            return nil
        }
    }
}

// MARK: - Вентиляторы

struct FanInfo: Identifiable, Equatable {
    let id: Int
    var actual: Double
    var min: Double
    var max: Double
    var forced: Bool
}

/// Логика вентиляторов поверх SMC. Чтение — от пользователя, запись — только от root (помощник).
enum FanSMC {
    static func count(_ smc: SMCConnection) -> Int {
        guard smc.isOpen else { return 0 }
        return Int(smc.readDouble("FNum") ?? 0)
    }

    static func readFans(_ smc: SMCConnection) -> [FanInfo] {
        let n = count(smc)
        guard n > 0 else { return [] }
        let forcedMask = Int(smc.readDouble("FS! ") ?? 0)
        return (0..<n).map { i in
            let mode = smc.readDouble("F\(i)Md")
            let forced = mode.map { $0 >= 1 } ?? ((forcedMask >> i) & 1 == 1)
            return FanInfo(id: i,
                           actual: smc.readDouble("F\(i)Ac") ?? 0,
                           min: smc.readDouble("F\(i)Mn") ?? 0,
                           max: smc.readDouble("F\(i)Mx") ?? 0,
                           forced: forced)
        }
    }

    /// Ручная скорость. На Apple Silicon сначала включается тестовый режим Ftst, иначе Md не примется.
    static func setManual(_ smc: SMCConnection, index: Int, rpm: Double) -> Bool {
        let md = "F\(index)Md"
        if smc.hasKey("Ftst") { _ = smc.write("Ftst", value: 1) }
        if smc.hasKey(md) {
            var ok = false
            for _ in 0..<20 {
                if smc.write(md, value: 1), (smc.readDouble(md) ?? 0) >= 1 {
                    ok = true
                    break
                }
                usleep(150_000)
            }
            if !ok { return false }
        } else if smc.hasKey("FS! ") {
            let current = Int(smc.readDouble("FS! ") ?? 0)
            _ = smc.write("FS! ", value: Double(current | (1 << index)))
        }
        let minRPM = smc.readDouble("F\(index)Mn") ?? 0
        let maxRPM = smc.readDouble("F\(index)Mx") ?? rpm
        let target = Swift.min(Swift.max(rpm, minRPM), maxRPM > 0 ? maxRPM : rpm)
        return smc.write("F\(index)Tg", value: target)
    }

    static func setAuto(_ smc: SMCConnection, index: Int) {
        let md = "F\(index)Md"
        if smc.hasKey(md) {
            _ = smc.write(md, value: 0)
        } else if smc.hasKey("FS! ") {
            let current = Int(smc.readDouble("FS! ") ?? 0)
            _ = smc.write("FS! ", value: Double(current & ~(1 << index)))
        }
        // Если ни один вентилятор больше не в ручном режиме — выключить тестовый режим.
        let anyForced = readFans(smc).contains { $0.forced }
        if !anyForced && smc.hasKey("Ftst") { _ = smc.write("Ftst", value: 0) }
    }

    static func setAllAuto(_ smc: SMCConnection) {
        let n = count(smc)
        for i in 0..<n {
            if smc.hasKey("F\(i)Md") { _ = smc.write("F\(i)Md", value: 0) }
        }
        if smc.hasKey("FS! ") { _ = smc.write("FS! ", value: 0) }
        if smc.hasKey("Ftst") { _ = smc.write("Ftst", value: 0) }
    }
}

// MARK: - Режим помощника (запускается от root через sudo)

/// `<helper> --smc read <KEY>` · `write <KEY> <число>` · `set <№> <об/мин>` · `auto [№]`.
/// Записывать разрешено только ключи вентиляторов — помощник работает от root.
enum SMCHelperCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let cmd = args.first else {
            fputs("usage: --smc read KEY | write KEY VALUE | set INDEX RPM | auto [INDEX]\n", stderr)
            return 2
        }
        let smc = SMCConnection.shared
        guard smc.isOpen else {
            fputs("SMC недоступен\n", stderr)
            return 3
        }
        switch cmd {
        case "read":
            guard args.count >= 2, isValidKey(args[1]) else { return 2 }
            if let v = smc.readDouble(args[1]) {
                print(v)
                return 0
            }
            return 1
        case "write":
            guard args.count >= 3, isValidKey(args[1]), isWritableKey(args[1]), let v = Double(args[2]) else { return 2 }
            return smc.write(args[1], value: v) ? 0 : 1
        case "set":
            guard args.count >= 3, let i = Int(args[1]), i >= 0, i < 10, let rpm = Double(args[2]), rpm >= 0 else { return 2 }
            return FanSMC.setManual(smc, index: i, rpm: rpm) ? 0 : 1
        case "auto":
            if args.count >= 2, let i = Int(args[1]), i >= 0, i < 10 {
                FanSMC.setAuto(smc, index: i)
            } else {
                FanSMC.setAllAuto(smc)
            }
            return 0
        default:
            return 2
        }
    }

    private static func isValidKey(_ k: String) -> Bool {
        k.utf8.count == 4 && k.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    private static func isWritableKey(_ k: String) -> Bool {
        if k == "Ftst" || k == "FS! " { return true }
        guard k.hasPrefix("F") else { return false }
        let chars = Array(k)
        guard chars.count == 4, chars[1].isNumber else { return false }
        let suffix = String(chars[2...3])
        return suffix == "Md" || suffix == "Tg" || suffix == "Mn"
    }
}
