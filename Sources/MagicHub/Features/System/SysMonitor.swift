import Foundation
import Combine

struct SysSnapshot {
    var cpu: Double = 0
    var perCore: [Double] = []
    var pCores = 0
    var eCores = 0
    var cpuTemp: Double?
    var memory = SysMemory()
    var uptime: TimeInterval = 0
    var battery: SysBattery?
    var fans: [FanInfo] = []
}

/// Периодический опрос датчиков в фоне. Интервал — Prefs.mbInterval.
/// Список процессов собирается только пока открыто окошко с подробностями (detailed = true).
final class SysMonitor: ObservableObject {
    static let shared = SysMonitor()

    @Published private(set) var snap = SysSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var batteryHistory: [Double] = []
    @Published private(set) var powerHistory: [Double] = []
    @Published private(set) var topCPU: [SysProcInfo] = []
    @Published private(set) var topMem: [SysProcInfo] = []

    /// true, пока открыт поповер — тогда же собираем процессы.
    var detailed = false {
        didSet {
            guard detailed != oldValue else { return }
            if detailed { refreshNow() }
            if Prefs.shared.lite { restart(interval: Prefs.shared.mbInterval) }
        }
    }

    private let queue = DispatchQueue(label: "app.magichub.sysmon", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private let cpuLoad = SysCPULoad()
    private var hid: SysHIDTemperature?
    private var hidTried = false
    private let layout = SysCtl.coreLayout()
    private var started = false
    private var tick = 0

    private let historyLimit = 60

    func start() {
        guard !started else { return }
        started = true
        restart(interval: Prefs.shared.mbInterval)
        Prefs.shared.$mbInterval.map { _ in () }
            .merge(with: Prefs.shared.$lite.removeDuplicates().map { _ in () })
            .dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.restart(interval: Prefs.shared.mbInterval) }
            .store(in: &cancellables)
    }

    func refreshNow() {
        queue.async { [weak self] in self?.sample() }
    }

    private func restart(interval: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // В экономном режиме — не чаще раза в 3 с (пока открыто окошко с подробностями, как задано).
        let effective = Prefs.shared.lite && !detailed ? max(3, interval) : max(1, interval)
        t.schedule(deadline: .now(), repeating: effective, leeway: .milliseconds(Prefs.shared.lite ? 1000 : 250))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    // Вызывается только на `queue`.
    private func sample() {
        tick += 1
        var s = SysSnapshot()
        let load = cpuLoad.sample()
        s.cpu = load.total
        s.perCore = load.perCore
        s.pCores = layout.p
        s.eCores = layout.e

        if !hidTried {
            hidTried = true
            if SysCtl.isAppleSilicon {
                let h = SysHIDTemperature()
                hid = h.isAvailable ? h : nil
            }
        }
        s.cpuTemp = hid?.cpuTemperature() ?? SysSMCTemperature.cpuTemperature()
        s.memory = SysMemory.read()
        s.uptime = SysCtl.uptime()
        s.battery = SysPower.read(includeDetails: true)
        if FanController.shared.hasFans {
            s.fans = FanSMC.readFans(SMCConnection.shared)
        }

        let wantProcs = detailed
        let procs = wantProcs ? SysProcesses.top(limit: 5) : nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snap = s
            self.append(&self.cpuHistory, s.cpu)
            if let b = s.battery {
                self.append(&self.batteryHistory, Double(b.percent) / 100)
                if let w = b.systemWatts { self.append(&self.powerHistory, w) }
            }
            if let procs {
                self.topCPU = procs.cpu
                self.topMem = procs.mem
            }
        }
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLimit { arr.removeFirst(arr.count - historyLimit) }
    }
}
