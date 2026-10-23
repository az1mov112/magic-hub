import AppKit
import SwiftUI
import Combine

/// Окошко под цифрами в меню-баре. Своё окно вместо NSPopover: NSPopover при изменении
/// размера содержимого (раскрыли список, сменили вкладку) улетал к левому краю экрана.
private final class SystemPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Цифры справа в меню-баре (CPU, температура, память, батарея, вентилятор).
/// Клик — окошко с подробностями «Система / Питание / Вентиляторы».
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    private let panel = SystemPanel()
    /// Верхний край и центр окошка — фиксируются при открытии, при смене высоты не двигаются.
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    private var contentHeight: CGFloat = 0
    /// Содержимое окошка создаётся при открытии и убирается при закрытии: скрытый SwiftUI-вид
    /// иначе перерисовывал бы графики и списки процессов каждые пару секунд впустую.
    private var makeContent: (() -> NSView)?
    private var monitors: [Any] = []
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

        makeContent = { [weak self] in
            let content = SystemPopoverView(
                onSettings: { [weak self] in
                    self?.closePanel()
                    AppModel.shared.open(.settings)
                },
                onActivityMonitor: { [weak self] in
                    self?.closePanel()
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.contentSizeChanged(size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            return host
        }

        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in self?.closePanel() }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in self?.closePanel() }

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
        if panel.isVisible {
            closePanel()
            return
        }
        guard let button = item?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        anchorTop = anchor.minY - 5
        anchorMidX = anchor.midX
        SysMonitor.shared.detailed = true
        panel.contentView = makeContent?()
        place(height: contentHeight > 1 ? contentHeight : 420)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        SysMonitor.shared.detailed = false
    }

    /// Высота меняется — верхний край остаётся под цифрами, окошко растёт вниз.
    private func contentSizeChanged(_ size: CGSize) {
        guard size.height > 1 else { return }
        contentHeight = ceil(size.height)
        if panel.isVisible, abs(contentHeight - panel.frame.height) > 0.5 {
            place(height: contentHeight)
        }
    }

    private func place(height: CGFloat) {
        let width: CGFloat = 340
        let h = ceil(height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorMidX, y: anchorTop)) } ?? NSScreen.main
        var x = anchorMidX - width / 2
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 6), vf.maxX - width - 6)
        }
        panel.setFrame(NSRect(x: round(x), y: anchorTop - h, width: width, height: h), display: true)
        panel.invalidateShadow()
    }

    /// Клик мимо окошка или Esc — закрыть, как у обычного всплывающего окна.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.closePanel()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.panel.isKeyWindow { self.closePanel(); return nil }
                return event
            }
            // Клик по самим цифрам закроет окошко через togglePopover.
            if event.window !== self.panel, event.window !== self.item?.button?.window { self.closePanel() }
            return event
        }) { monitors.append(m) }
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
            closePanel()
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
