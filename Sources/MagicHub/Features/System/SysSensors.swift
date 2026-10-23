import AppKit
import IOKit
import IOKit.ps
import Darwin

// Датчики системы: температуры, нагрузка CPU, память, батарея, процессы.
// Все функции вызываются из фоновой очереди SysMonitor.

enum SysCtl {
    static func int32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let boot = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - boot
    }

    static func swapUsed() -> Double {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return Double(swap.xsu_used)
    }

    /// Ядра производительности и эффективности (Apple Silicon). На Intel — (все, 0).
    static func coreLayout() -> (p: Int, e: Int) {
        let p = Int(int32("hw.perflevel0.logicalcpu") ?? 0)
        let e = Int(int32("hw.perflevel1.logicalcpu") ?? 0)
        if p > 0 && e > 0 { return (p, e) }
        return (ProcessInfo.processInfo.activeProcessorCount, 0)
    }

    static var isAppleSilicon: Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 { return v == 1 }
        return false
    }
}

// MARK: - Температуры (Apple Silicon: HID-датчики; Intel: SMC)

final class SysHIDTemperature {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var servicesArray: CFArray?
    private var sensors: [(name: String, service: UnsafeMutableRawPointer)] = []

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self) else { return }
        self.copyEvent = copyEvent
        self.getFloat = getFloat

        // Клиент живёт всё время работы приложения — не освобождаем.
        guard let client = create(nil) else { return }
        let matching: NSDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        withExtendedLifetime(matching) {
            setMatching(client, Unmanaged.passUnretained(matching).toOpaque())
        }
        guard let arrPtr = copyServices(client) else { return }
        let arr = Unmanaged<CFArray>.fromOpaque(arrPtr).takeRetainedValue()
        servicesArray = arr
        let productKey = "Product" as CFString
        let count = CFArrayGetCount(arr)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            var name = ""
            withExtendedLifetime(productKey) {
                if let p = copyProperty(service, Unmanaged.passUnretained(productKey).toOpaque()) {
                    let obj = Unmanaged<AnyObject>.fromOpaque(p).takeRetainedValue()
                    name = (obj as? String) ?? ""
                }
            }
            sensors.append((name: name, service: service))
        }
    }

    var isAvailable: Bool { !sensors.isEmpty }

    func readAll() -> [(name: String, value: Double)] {
        guard let copyEvent, let getFloat, servicesArray != nil else { return [] }
        let typeTemperature: Int64 = 15
        let field = Int32(15 << 16)
        var out: [(name: String, value: Double)] = []
        for s in sensors {
            guard let ev = copyEvent(s.service, typeTemperature, 0, 0) else { continue }
            let v = getFloat(ev, field)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            if v > 0 && v < 150 { out.append((name: s.name, value: v)) }
        }
        return out
    }

    /// Температура CPU: среднее по «PMU tdie*», иначе SOC/tdev, иначе максимум.
    func cpuTemperature() -> Double? {
        let all = readAll()
        guard !all.isEmpty else { return nil }
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        if let t = avg(all.filter { $0.name.contains("tdie") }.map { $0.value }) { return t }
        if let t = avg(all.filter { $0.name.contains("tdev") || $0.name.contains("SOC") }.map { $0.value }) { return t }
        let rest = all.filter {
            let n = $0.name.lowercased()
            return !n.contains("battery") && !n.contains("nand") && !n.contains("gas gauge")
        }
        return rest.map { $0.value }.max()
    }
}

enum SysSMCTemperature {
    static let intelKeys = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCXC"]
    static let armKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]

    static func cpuTemperature() -> Double? {
        let smc = SMCConnection.shared
        guard smc.isOpen else { return nil }
        if SysCtl.isAppleSilicon {
            let vals = armKeys.compactMap { smc.readDouble($0) }.filter { $0 > 5 && $0 < 130 }
            return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }
        for k in intelKeys {
            if let v = smc.readDouble(k), v > 5, v < 130 { return v }
        }
        return nil
    }
}

// MARK: - Нагрузка CPU

final class SysCPULoad {
    private var prev: [(busy: UInt64, total: UInt64)] = []
    private let host = mach_host_self()

    /// Нагрузка 0…1 в целом и по ядрам (в порядке ядер системы).
    func sample() -> (total: Double, perCore: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return (0, []) }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        var current: [(busy: UInt64, total: UInt64)] = []
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = stride * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + system + nice, user + system + nice + idle))
        }
        var per: [Double] = []
        var busySum: UInt64 = 0
        var totalSum: UInt64 = 0
        for (i, c) in current.enumerated() {
            if i < prev.count {
                let db = c.busy >= prev[i].busy ? c.busy - prev[i].busy : 0
                let dt = c.total >= prev[i].total ? c.total - prev[i].total : 0
                per.append(dt > 0 ? Double(db) / Double(dt) : 0)
                busySum += db
                totalSum += dt
            } else {
                per.append(0)
            }
        }
        prev = current
        let total = totalSum > 0 ? Double(busySum) / Double(totalSum) : 0
        return (total, per)
    }
}

// MARK: - Память

struct SysMemory {
    var used: Double = 0
    var total: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var compressed: Double = 0
    var cached: Double = 0
    var swap: Double = 0
    /// 1 — норма, 2 — предупреждение, 4 — критично.
    var pressure: Int = 1

    private static let host = mach_host_self()

    static func read() -> SysMemory {
        var m = SysMemory()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics64(host, HOST_VM_INFO64, p, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let internalPages = Double(stats.internal_page_count)
            let purgeable = Double(stats.purgeable_count)
            let wired = Double(stats.wire_count)
            let compressed = Double(stats.compressor_page_count)
            let external = Double(stats.external_page_count)
            m.used = max(0, internalPages - purgeable + wired + compressed) * page
            m.compressed = compressed * page
            m.cached = (external + purgeable) * page
        }
        m.swap = SysCtl.swapUsed()
        m.pressure = Int(SysCtl.int32("kern.memorystatus_vm_pressure_level") ?? 1)
        return m
    }
}

// MARK: - Батарея и питание

struct SysBattery: Equatable {
    var percent: Int = 0
    var isCharging = false
    var onAC = false
    /// Секунды; nil — система ещё не знает.
    var timeRemaining: TimeInterval?
    var temperature: Double?
    var cycles: Int?
    /// Максимальная ёмкость — как в «Системных настройках → Аккумулятор».
    var health: Double?
    /// Сколько батарея вмещает прямо сейчас относительно новой (сырое значение, плавает с температурой).
    var rawHealth: Double?
    /// Потребление всей системы, Вт.
    var systemWatts: Double?
    /// + заряжается, − отдаёт, Вт.
    var batteryWatts: Double?
}

enum SysPower {
    /// nil — у Mac нет батареи.
    static func read(includeDetails: Bool = true) -> SysBattery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc["Type"] as? String) == "InternalBattery" else { continue }
            var b = SysBattery()
            let cur = (desc["Current Capacity"] as? Int) ?? 0
            let maxCap = (desc["Max Capacity"] as? Int) ?? 100
            b.percent = maxCap > 0 ? Int((Double(cur) / Double(maxCap) * 100).rounded()) : cur
            b.isCharging = (desc["Is Charging"] as? Bool) ?? false
            b.onAC = (desc["Power Source State"] as? String) == "AC Power"
            let est = IOPSGetTimeRemainingEstimate()
            if est > 0 { b.timeRemaining = est }
            if let mins = desc["Time to Empty"] as? Int, mins > 0, !b.onAC { b.timeRemaining = Double(mins) * 60 }
            if includeDetails, let sb = smartBattery() { fillDetails(&b, sb) }
            return b
        }
        return nil
    }

    static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return true }
        return (type as String) == "AC Power"
    }

    /// Только температура батареи — без чтения всего реестра AppleSmartBattery.
    static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let n = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber, n.doubleValue > 0 else { return nil }
        return n.doubleValue / 100
    }

    static func smartBattery() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    private static func signed(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        var v = n.int64Value
        if v > Int64(Int32.max) && v <= Int64(UInt32.max) { v -= Int64(UInt32.max) + 1 }
        return Int(v)
    }

    private static func fillDetails(_ b: inout SysBattery, _ d: [String: Any]) {
        if let t = d["Temperature"] as? NSNumber, t.doubleValue > 0 {
            b.temperature = t.doubleValue / 100
        }
        b.cycles = (d["CycleCount"] as? NSNumber)?.intValue
        // Как считает macOS: готовый процент (Apple Silicon), иначе номинальная ёмкость к проектной.
        // Сырая AppleRawMaxCapacity ниже и плавает — её показываем отдельно.
        let design = (d["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
        let raw = (d["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue ?? 0
        if design > 0, raw > 0 { b.rawHealth = min(100, raw / design * 100) }
        if let pct = ((d["BatteryData"] as? [String: Any])?["MaximumCapacityPercent"] as? NSNumber)?.doubleValue, pct > 0 {
            b.health = min(100, pct)
        } else if let nominal = (d["NominalChargeCapacity"] as? NSNumber)?.doubleValue, nominal > 0, design > 0 {
            b.health = min(100, nominal / design * 100)
        } else if let maxCap = (d["MaxCapacity"] as? NSNumber)?.doubleValue, maxCap > 0 {
            b.health = maxCap > 100 && design > 0 ? min(100, maxCap / design * 100) : min(100, maxCap)
        } else {
            b.health = b.rawHealth
        }
        if let v = signed(d["Voltage"]), let a = signed(d["InstantAmperage"] ?? d["Amperage"]) {
            b.batteryWatts = Double(v) * Double(a) / 1_000_000
        }
        if let tele = d["PowerTelemetryData"] as? [String: Any], let load = (tele["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            b.systemWatts = load / 1000
        } else if let w = b.batteryWatts, !b.onAC {
            b.systemWatts = abs(w)
        }
    }
}

// MARK: - Процессы

struct SysProcInfo: Identifiable {
    var id: String { name }
    let name: String
    let cpu: Double        // проценты
    let memBytes: Double
    let icon: NSImage?
}

enum SysProcesses {
    static func top(limit: Int = 5) -> (cpu: [SysProcInfo], mem: [SysProcInfo]) {
        let r = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="])
        guard r.ok else { return ([], []) }
        var byName: [String: (cpu: Double, mem: Double, icon: NSImage?)] = [:]
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]) else { continue }
            let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
            let rssKB = Double(parts[2]) ?? 0
            var name = String(parts[3])
            var icon: NSImage?
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited {
                name = app.localizedName ?? name
                icon = app.icon
            }
            var entry = byName[name] ?? (cpu: 0.0, mem: 0.0, icon: icon)
            entry.cpu += cpu
            entry.mem += rssKB * 1024
            if entry.icon == nil { entry.icon = icon }
            byName[name] = entry
        }
        let all = byName.map { SysProcInfo(name: $0.key, cpu: $0.value.cpu, memBytes: $0.value.mem, icon: $0.value.icon) }
        let cpu = Array(all.sorted { $0.cpu > $1.cpu }.prefix(limit))
        let mem = Array(all.sorted { $0.memBytes > $1.memBytes }.prefix(limit))
        return (cpu, mem)
    }
}
