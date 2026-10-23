import AppKit
import SwiftUI
import Combine

/// Цифры справа в меню-баре (CPU, температура, память, батарея, вентилятор).
/// Клик — окошко с подробностями «Система / Питание / Вентиляторы».
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private override init() { super.init() }

    func start() {
        guard !started else { return }
        started = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Показатели системы Magic Hub")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: SystemPopoverView(
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                AppModel.shared.open(.settings)
            },
            onActivityMonitor: { [weak self] in
                self?.popover.performClose(nil)
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        ))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        FanController.shared.recoverIfNeeded()
        SysMonitor.shared.start()

        SysMonitor.shared.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &cancellables)

        let p = Prefs.shared
        Publishers.MergeMany(
            p.$mbCPU.map { _ in () }.eraseToAnyPublisher(),
            p.$mbCPUTemp.map { _ in () }.eraseToAnyPublisher(),
            p.$mbRAM.map { _ in () }.eraseToAnyPublisher(),
            p.$mbBatteryTemp.map { _ in () }.eraseToAnyPublisher(),
            p.$mbFan.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.redraw() }
        .store(in: &cancellables)

        redraw()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = item?.button else { return }
        SysMonitor.shared.detailed = true
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        SysMonitor.shared.detailed = false
    }

    // MARK: - Картинка в меню-баре

    private func redraw() {
        guard let item else { return }
        let p = Prefs.shared
        let s = SysMonitor.shared.snap
        var cols: [(String, String)] = []
        if p.mbCPU { cols.append(("CPU", "\(Int((s.cpu * 100).rounded()))%")) }
        if p.mbCPUTemp { cols.append(("CPU °C", s.cpuTemp.map { "\(Int($0.rounded()))°" } ?? "—")) }
        if p.mbRAM {
            let pct = s.memory.total > 0 ? Int((s.memory.used / s.memory.total * 100).rounded()) : 0
            cols.append(("RAM", "\(pct)%"))
        }
        if p.mbBatteryTemp, let b = s.battery {
            cols.append(("BAT °C", b.temperature.map { "\(Int($0.rounded()))°" } ?? "—"))
        }
        if p.mbFan, FanController.shared.hasFans {
            cols.append(("FAN", s.fans.first.map { "\(Int($0.actual))" } ?? "—"))
        }
        if cols.isEmpty {
            item.isVisible = false
            return
        }
        item.isVisible = true
        item.button?.image = StatusBarController.makeImage(cols)
    }

    static func makeImage(_ cols: [(String, String)]) -> NSImage {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let widths: [CGFloat] = cols.map { col in
            max((col.0 as NSString).size(withAttributes: labelAttrs).width,
                (col.1 as NSString).size(withAttributes: valueAttrs).width)
        }
        let spacing: CGFloat = 7
        let total = ceil(widths.reduce(0, +) + spacing * CGFloat(max(0, cols.count - 1)))
        let height: CGFloat = 22
        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, col) in cols.enumerated() {
                (col.0 as NSString).draw(at: NSPoint(x: x, y: 13), withAttributes: labelAttrs)
                (col.1 as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: valueAttrs)
                x += widths[i] + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
