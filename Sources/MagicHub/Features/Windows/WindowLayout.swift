import AppKit
import SwiftUI
import Combine
import ApplicationServices
import Carbon.HIToolbox

/// Шаблон раскладки окна. Зона задаётся в долях видимой области экрана (без меню-бара и Dock), начало — сверху слева.
enum WindowLayout: Int, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, center, topHalf, bottomHalf

    var id: Int { rawValue }

    /// Шаблоны в полосе под чёлкой (верхняя и нижняя половины — только с клавиатуры).
    static let strip: [WindowLayout] = [.leftHalf, .rightHalf, .topLeft, .topRight, .bottomLeft, .bottomRight,
                                        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                                        .maximize, .center]

    var title: String {
        switch self {
        case .leftHalf: return "Левая половина"
        case .rightHalf: return "Правая половина"
        case .topLeft: return "Слева сверху"
        case .topRight: return "Справа сверху"
        case .bottomLeft: return "Слева снизу"
        case .bottomRight: return "Справа снизу"
        case .leftThird: return "Левая треть"
        case .centerThird: return "Средняя треть"
        case .rightThird: return "Правая треть"
        case .leftTwoThirds: return "Две трети слева"
        case .rightTwoThirds: return "Две трети справа"
        case .maximize: return "Весь экран"
        case .center: return "По центру"
        case .topHalf: return "Верхняя половина"
        case .bottomHalf: return "Нижняя половина"
        }
    }

    var unit: CGRect {
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: return CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.76)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        }
    }

    /// Зона в координатах AppKit (начало — снизу слева), с отступами 8 pt между окнами и от краёв.
    func frame(in visible: CGRect) -> CGRect {
        let u = unit
        let gap: CGFloat = 8
        if self == .center {
            let w = visible.width * u.width, h = visible.height * u.height
            return CGRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h).integral
        }
        let left = u.minX < 0.001 ? gap : gap / 2
        let right = u.maxX > 0.999 ? gap : gap / 2
        let top = u.minY < 0.001 ? gap : gap / 2
        let bottom = u.maxY > 0.999 ? gap : gap / 2
        let x = visible.minX + u.minX * visible.width + left
        let w = u.width * visible.width - left - right
        let h = u.height * visible.height - top - bottom
        let y = visible.maxY - u.minY * visible.height - top - h
        return CGRect(x: x, y: y, width: w, height: h).integral
    }
}

/// Раскладка окон: перетащите окно к чёлке — появятся шаблоны; отпустите на шаблоне — окно встанет в зону.
/// Плюс горячие клавиши ⌃⌥ для активного окна. Окна двигаются через Accessibility API.
final class WindowLayoutManager: ObservableObject {
    static let shared = WindowLayoutManager()

    /// Сейчас тащат окно (не файл и не выделение текста).
    @Published private(set) var windowDragging = false
    @Published private(set) var trusted = AXIsProcessTrusted()

    private let ax = DispatchQueue(label: "app.magichub.windows.ax", qos: .userInteractive)
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    // Состояние текущего перетаскивания.
    private var candidate: AXUIElement?
    private var startPosition: CGPoint?
    private var lastProbe = Date.distantPast
    private var probing = false
    private weak var stripController: NotchController?
    private var hovered: WindowLayout?
    private var targetScreen: NSScreen?

    private let preview = LayoutPreviewWindow()

    // Горячие клавиши.
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    static let hotKeys: [(key: Int, symbol: String, layout: WindowLayout)] = [
        (kVK_LeftArrow, "←", .leftHalf), (kVK_RightArrow, "→", .rightHalf),
        (kVK_UpArrow, "↑", .topHalf), (kVK_DownArrow, "↓", .bottomHalf),
        (kVK_Return, "↩", .maximize), (kVK_ANSI_C, "C", .center),
        (kVK_ANSI_U, "U", .topLeft), (kVK_ANSI_I, "I", .topRight),
        (kVK_ANSI_J, "J", .bottomLeft), (kVK_ANSI_K, "K", .bottomRight),
        (kVK_ANSI_D, "D", .leftThird), (kVK_ANSI_F, "F", .centerThird), (kVK_ANSI_G, "G", .rightThird),
        (kVK_ANSI_E, "E", .leftTwoThirds), (kVK_ANSI_T, "T", .rightTwoThirds)
    ]

    func start() {
        let p = Prefs.shared
        p.$windowLayout.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateMonitors() } }
            .store(in: &cancellables)
        p.$layoutHotkeys.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateHotKeys() } }
            .store(in: &cancellables)
        // Разрешение «Универсальный доступ» могут выдать в любой момент.
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let t = AXIsProcessTrusted()
                if t != self.trusted { self.trusted = t; self.updateMonitors() }
            }
            .store(in: &cancellables)
    }

    // MARK: Перетаскивание окна к чёлке

    private func updateMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
        guard Prefs.shared.windowLayout, trusted else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.mouseDown(NSEvent.mouseLocation)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            self?.mouseDragged(NSEvent.mouseLocation)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.mouseUp()
        }) { monitors.append(m) }
    }

    private func mouseDown(_ p: NSPoint) {
        reset()
        let axPoint = Self.toAX(p)
        ax.async { [weak self] in
            guard let window = Self.window(at: axPoint), let pos = Self.position(of: window),
                  let size = Self.size(of: window) else { return }
            // Окно перетаскивают за заголовок: курсор в верхних ~40 pt окна.
            guard axPoint.y - pos.y < 40, axPoint.y >= pos.y, axPoint.x >= pos.x, axPoint.x <= pos.x + size.width else { return }
            DispatchQueue.main.async {
                self?.candidate = window
                self?.startPosition = pos
            }
        }
    }

    private func mouseDragged(_ p: NSPoint) {
        guard candidate != nil else { return }
        if !windowDragging {
            guard !probing, Date().timeIntervalSince(lastProbe) > 0.08, let window = candidate, let start = startPosition else { return }
            probing = true
            lastProbe = Date()
            ax.async { [weak self] in
                let moved = Self.position(of: window).map { abs($0.x - start.x) + abs($0.y - start.y) > 3 } ?? false
                DispatchQueue.main.async {
                    self?.probing = false
                    if moved { self?.windowDragging = true }
                }
            }
            return
        }
        updateStrip(p)
    }

    private func mouseUp() {
        let window = candidate
        let layout = hovered
        let screen = targetScreen
        reset()
        guard let window, let layout, let screen else { return }
        // Отпустили на шаблоне. macOS ещё может доводить окно после перетаскивания — ставим дважды.
        let target = layout.frame(in: screen.visibleFrame)
        for delay in [0.06, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.ax.async { Self.setFrame(window, to: target) }
            }
        }
    }

    private func reset() {
        candidate = nil
        startPosition = nil
        probing = false
        if windowDragging { windowDragging = false }
        hideStrip()
    }

    /// Полоса шаблонов под чёлкой экрана, где курсор.
    private func updateStrip(_ p: NSPoint) {
        guard let c = NotchManager.shared.controllers.first(where: { $0.screen.frame.contains(p) }) else {
            hideStrip()
            return
        }
        let g = c.model.geometry
        let size = g.layoutSize
        let f = g.screenFrame
        let near = p.y >= f.maxY - 70 && abs(p.x - f.midX) <= size.width / 2 + 60
        let stay = c.model.layoutActive && p.y >= f.maxY - size.height - 90 && abs(p.x - f.midX) <= size.width / 2 + 120
        guard near || stay else {
            hideStrip()
            return
        }
        if stripController !== c {
            hideStrip()
            stripController = c
            c.model.layoutActive = true
            c.panel.ignoresMouseEvents = true
        }
        targetScreen = c.screen
        let layout = g.layoutIndex(at: p).map { WindowLayout.strip[$0] }
        if layout != hovered {
            hovered = layout
            c.model.layoutHover = layout
            if let layout {
                preview.show(layout.frame(in: c.screen.visibleFrame))
            } else {
                preview.hide()
            }
        }
    }

    private func hideStrip() {
        if let c = stripController {
            c.model.layoutActive = false
            c.model.layoutHover = nil
            c.handleMove(NSEvent.mouseLocation)
        }
        stripController = nil
        hovered = nil
        targetScreen = nil
        preview.hide()
    }

    // MARK: Горячие клавиши

    private func updateHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        guard Prefs.shared.layoutHotkeys else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let index = Int(hk.id)
                DispatchQueue.main.async { WindowLayoutManager.shared.hotKeyPressed(index) }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        let modifiers = UInt32(controlKey | optionKey)
        for (i, binding) in Self.hotKeys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D48_4C59), id: UInt32(i))   // 'MHLY'
            if RegisterEventHotKey(UInt32(binding.key), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func hotKeyPressed(_ index: Int) {
        guard Self.hotKeys.indices.contains(index) else { return }
        guard AXIsProcessTrusted() else {
            AppModel.shared.post(NotchNotification(title: "Нужен «Универсальный доступ»",
                                                   subtitle: "Без него Magic Hub не может двигать окна",
                                                   kind: .warning, icon: "macwindow",
                                                   onTap: { PermissionsCenter.shared.requestAll() }))
            return
        }
        let layout = Self.hotKeys[index].layout
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        ax.async {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
            let window = raw as! AXUIElement
            // Экран — тот, где сейчас центр окна.
            let screen: NSScreen? = DispatchQueue.main.sync {
                guard let pos = Self.position(of: window), let size = Self.size(of: window) else { return NSScreen.main }
                let center = Self.fromAX(CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2))
                return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
            }
            guard let screen else { return }
            Self.setFrame(window, to: layout.frame(in: screen.visibleFrame))
        }
    }

    // MARK: Accessibility

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit (снизу слева) → Accessibility (сверху слева, от основного экрана).
    static func toAX(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static func fromAX(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }

    private static func window(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)   // зависшее приложение не должно тормозить остальные клики
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              var el = element else { return nil }
        // Наши собственные окна не трогаем.
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        for _ in 0..<12 {
            if role(of: el) == (kAXWindowRole as String) { return el }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &value) == .success,
               let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                return (raw as! AXUIElement)
            }
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &value) == .success,
                  let parent = value, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }

    private static func role(of el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Поставить окно в зону (координаты AppKit). Размер — до и после сдвига: часть окон не растягивается за край экрана.
    static func setFrame(_ window: AXUIElement, to frame: CGRect) {
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
    }
}

/// Полупрозрачный прямоугольник: где окажется окно.
final class LayoutPreviewWindow {
    private var panel: NSPanel?

    func show(_ frame: CGRect) {
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible {
            p.setFrame(frame, display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            if p.alphaValue < 0.01 { p.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MH.accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MH.accent.opacity(0.75), lineWidth: 2))
                .padding(2)
        )
        host.sizingOptions = []
        p.contentView = host
        return p
    }
}

/// Полоса шаблонов под чёлкой.
struct LayoutStripView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let g = model.geometry
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("РАСКЛАДКА ОКНА")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.9)
                    .foregroundStyle(MH.t3)
                Text(model.layoutHover?.title ?? "отпустите окно на шаблоне")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.layoutHover == nil ? MH.t3 : MH.t1)
            }
            .frame(height: 14)
            HStack(spacing: NotchGeometry.layoutGap) {
                ForEach(Array(WindowLayout.strip.enumerated()), id: \.offset) { _, layout in
                    LayoutTile(layout: layout, active: model.layoutHover == layout)
                        .frame(width: NotchGeometry.layoutTile.width, height: NotchGeometry.layoutTile.height)
                }
            }
        }
        .padding(.top, g.layoutTopInset)
        .padding(.horizontal, NotchGeometry.layoutPadding)
        .frame(width: g.layoutSize.width, height: g.layoutSize.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: model.layoutHover)
    }
}

private struct LayoutTile: View {
    let layout: WindowLayout
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let u = layout.unit
            let inset: CGFloat = 3.5
            let w = geo.size.width - inset * 2, h = geo.size.height - inset * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.45 : 0))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 1 : 0.55), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white.opacity(active ? 1 : 0.7))
                    .frame(width: max(2, u.width * w - 1.5), height: max(2, u.height * h - 1.5))
                    .offset(x: inset + u.minX * w + 0.75, y: inset + u.minY * h + 0.75)
            }
        }
        .scaleEffect(active ? 1.12 : 1)
        .shadow(color: .white.opacity(active ? 0.25 : 0), radius: 6)
    }
}

/// Настройки раскладки окон.
struct WindowsSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var manager = WindowLayoutManager.shared

    var body: some View {
        SettingsSection("Окна") {
            SettingsToggleRow("Раскладка окон через чёлку",
                              subtitle: "Тащите окно за заголовок к чёлке — появятся шаблоны: половины, четверти, трети",
                              isOn: $prefs.windowLayout)
            SettingsToggleRow("Горячие клавиши ⌃⌥",
                              subtitle: "Для активного окна: " + WindowLayoutManager.hotKeys.prefix(6).map { "\($0.symbol) \($0.layout.title.lowercased())" }.joined(separator: ", ")
                                  + "; U I J K — четверти, D F G — трети, E T — две трети",
                              isOn: $prefs.layoutHotkeys)
            if !manager.trusted {
                SettingsButtonRow("Нужен «Универсальный доступ»",
                                  subtitle: "Без него Magic Hub не может двигать окна других приложений",
                                  buttonTitle: "Разрешить") {
                    PermissionsCenter.shared.requestAll()
                }
            }
            SettingsToggleRow("Файл к чёлке — открыть полку",
                              subtitle: "Перетащите файл к чёлке — она раскроется, отпустите — файл ляжет на полку (без копирования)",
                              isOn: $prefs.shelfDragOpen)
        }
    }
}
