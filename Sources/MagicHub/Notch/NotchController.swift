import AppKit
import SwiftUI
import Combine

enum NotchMode: Equatable { case idle, live, hud, notif, open, layout, drop }

/// Размеры чёлки для конкретного экрана.
/// wide — своя чёлка на Mac без выреза (как в Cyclop), cutout — под настоящий вырез.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let hasHardwareNotch: Bool
    let notchSize: CGSize
    let menuBarHeight: CGFloat
    let style: NotchStyle   // .wide или .cutout (без .auto)
    /// Масштаб раскрытой панели (настройка «Размер панели»): 0,8…1,1.
    let panelScale: CGFloat

    /// Окно чуть больше самой большой панели — с запасом под тень.
    static let windowSize = CGSize(width: 980, height: 520)

    static func make(for screen: NSScreen, preferred: NotchStyle, scale: CGFloat = CGFloat(Prefs.shared.panelScale)) -> NotchGeometry {
        let f = screen.frame
        var hasNotch = false
        var notch = CGSize(width: 200, height: 32)
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            notch = CGSize(width: max(120, f.width - l.width - r.width), height: screen.safeAreaInsets.top)
        }
        let reserved = f.maxY - screen.visibleFrame.maxY
        let menuBar = max(NSStatusBar.system.thickness, reserved > 0 && reserved < 60 ? reserved : 0)
        let style: NotchStyle = preferred == .auto ? (hasNotch ? .cutout : .wide) : preferred
        if style == .cutout && !hasNotch {
            // «Высокая чёлка» на экране без выреза.
            notch = CGSize(width: 200, height: max(menuBar, 32))
        }
        return NotchGeometry(screenFrame: f, hasHardwareNotch: hasNotch, notchSize: notch, menuBarHeight: menuBar, style: style,
                             panelScale: min(1.2, max(0.7, scale)))
    }

    var isCutout: Bool { style == .cutout }

    var idleSize: CGSize { isCutout ? notchSize : CGSize(width: 220, height: 9) }
    /// Живая чёлка не шире 240 точек: на Mac без выреза значки меню-бара доходят почти до центра.
    var liveSize: CGSize { isCutout ? CGSize(width: notchSize.width + 110, height: notchSize.height) : CGSize(width: 240, height: max(menuBarHeight, 24)) }
    var notifSize: CGSize { isCutout ? CGSize(width: max(notchSize.width + 270, 470), height: notchSize.height + 64) : CGSize(width: 440, height: 74) }
    /// Размер панели при масштабе 100 %.
    var baseOpenSize: CGSize { isCutout ? CGSize(width: 720, height: notchSize.height + 344) : CGSize(width: 820, height: 344) }
    /// Реальный размер: всё ниже верхнего отступа (под вырезом) уменьшается пропорционально.
    var openSize: CGSize {
        CGSize(width: (baseOpenSize.width * panelScale).rounded(),
               height: (headerTop + (baseOpenSize.height - headerTop) * panelScale).rounded())
    }
    /// Индикатор громкости/яркости: под вырезом — «крылья» по бокам выреза, иначе — плашка чуть ниже меню-бара.
    var hudSize: CGSize { isCutout ? CGSize(width: notchSize.width + 210, height: notchSize.height) : CGSize(width: 250, height: max(menuBarHeight, 24) + 18) }
    // Полоса шаблонов раскладки окон: плитки фиксированного размера, чтобы попадание курсора
    // считалось по тем же числам, по которым они нарисованы.
    static let layoutTile = CGSize(width: 50, height: 32)
    static let layoutGap: CGFloat = 16
    static let layoutPadding: CGFloat = 22
    var layoutTopInset: CGFloat { (isCutout ? notchSize.height : max(menuBarHeight, 24)) + 8 }
    var layoutSize: CGSize {
        let n = CGFloat(WindowLayout.strip.count)
        let w = Self.layoutPadding * 2 + n * Self.layoutTile.width + (n - 1) * Self.layoutGap
        return CGSize(width: w, height: layoutTopInset + 14 + 10 + Self.layoutTile.height + 16)
    }

    // Полоса действий для файла, который тащат к чёлке.
    static let dropCard = CGSize(width: 100, height: 168)
    static let dropGap: CGFloat = 10
    static let dropPadding: CGFloat = 16
    var dropTopInset: CGFloat { (isCutout ? notchSize.height : max(menuBarHeight, 24)) + 8 }
    var dropSize: CGSize {
        let n = CGFloat(DropAction.allCases.count)
        return CGSize(width: Self.dropPadding * 2 + n * Self.dropCard.width + (n - 1) * Self.dropGap,
                      height: dropTopInset + 14 + 8 + Self.dropCard.height + 16)
    }

    /// Номер шаблона под курсором (координаты экрана) — по горизонтали, с допуском по высоте.
    func layoutIndex(at p: NSPoint) -> Int? {
        let size = layoutSize
        let left = screenFrame.midX - size.width / 2 + Self.layoutPadding
        guard p.y >= screenFrame.maxY - size.height - 60 else { return nil }
        let step = Self.layoutTile.width + Self.layoutGap
        let x = p.x - left + Self.layoutGap / 2
        guard x >= 0 else { return nil }
        let i = Int(x / step)
        return i < WindowLayout.strip.count ? i : nil
    }

    var headerTop: CGFloat { isCutout ? notchSize.height + 8 : 9 }
    var contentTop: CGFloat { isCutout ? notchSize.height + 36 : 38 }

    func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .idle: return idleSize
        case .live: return liveSize
        case .hud: return hudSize
        case .notif: return notifSize
        case .open: return openSize
        case .layout: return layoutSize
        case .drop: return dropSize
        }
    }

    func cornerRadius(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .open: return 26
        case .layout: return 22
        case .drop: return 26
        case .notif: return 24
        case .live: return isCutout ? 12 : 14
        case .hud: return isCutout ? 14 : 18
        case .idle: return isCutout ? 12 : 8
        }
    }

    /// Прямоугольник в координатах экрана, прижатый к верхнему краю по центру.
    func screenRect(for size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Состояние чёлки на одном экране.
final class NotchModel: ObservableObject {
    @Published var isOpen = false
    @Published var geometry: NotchGeometry
    /// Тащат окно к чёлке — показать шаблоны раскладки.
    @Published var layoutActive = false
    @Published var layoutHover: WindowLayout?
    /// Тащат файл к чёлке — показать полосу действий.
    @Published var dropActive = false

    init(geometry: NotchGeometry) { self.geometry = geometry }

    var mode: NotchMode {
        if isOpen { return .open }
        if layoutActive { return .layout }
        if dropActive { return .drop }
        if HUDModel.shared.current != nil { return .hud }
        if AppModel.shared.notification != nil { return .notif }
        // «Не спать» чёлку не расширяет — его значок в меню-баре (вместо сердечка).
        if Prefs.shared.liveIndicators && (NowPlayingModel.shared.isPlaying || JarvisMonitor.shared.isBusy) {
            return .live
        }
        return .idle
    }
}

/// Прозрачная панель поверх меню-бара. Не активирует приложение, но может принимать ввод с клавиатуры.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Одна чёлка на одном экране: окно, наведение мыши, открытие и закрытие.
final class NotchController {
    let screen: NSScreen
    let model: NotchModel
    let panel: NotchPanel
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    init(screen: NSScreen) {
        self.screen = screen
        let g = NotchGeometry.make(for: screen, preferred: Prefs.shared.notchStyle)
        model = NotchModel(geometry: g)
        panel = NotchPanel(frame: NotchController.windowFrame(for: g))
        let host = NSHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchGeometry.windowSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    static func windowFrame(for g: NotchGeometry) -> NSRect {
        let s = NotchGeometry.windowSize
        return NSRect(x: g.screenFrame.midX - s.width / 2, y: g.screenFrame.maxY - s.height, width: s.width, height: s.height)
    }

    func teardown() {
        openWork?.cancel()
        closeWork?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    /// Зона, где мышь «внутри» чёлки в текущем состоянии.
    /// Сверху зона выходит за край экрана: курсор, упёртый в самый верх, имеет y == maxY,
    /// а CGRect.contains верхнюю границу не включает.
    private var activeRect: CGRect {
        let g = model.geometry
        var r: CGRect
        if model.isOpen {
            r = g.screenRect(for: g.openSize).insetBy(dx: -6, dy: -6)
        } else {
            // Ровно по видимой форме (с запасом 2 pt): панель не раскрывается, пока курсор не на самой чёлке.
            r = g.screenRect(for: g.size(for: model.mode)).insetBy(dx: -2, dy: -2)
        }
        r.size.height += 20
        return r
    }

    func handleMove(_ p: NSPoint) {
        if model.layoutActive {
            panel.ignoresMouseEvents = true
            cancelOpen()
            return
        }
        if model.dropActive {
            // Окно должно принимать перетаскивание, пока курсор над полосой действий.
            let g = model.geometry
            var r = g.screenRect(for: g.dropSize).insetBy(dx: -30, dy: -30)
            r.size.height += 30
            let inside = r.contains(p)
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
            cancelOpen()
            cancelClose()
            return
        }
        let inside = activeRect.contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let prefs = Prefs.shared
        let app = AppModel.shared
        if model.isOpen {
            if inside || prefs.openMode == .click || app.pinnedOpen || app.fileDragActive || Date() < app.holdOpenUntil {
                cancelClose()
            } else {
                scheduleClose()
            }
        } else if prefs.openMode == .hover && inside && !WindowLayoutManager.shared.windowDragging {
            scheduleOpen()
        } else {
            cancelOpen()
        }
    }

    /// Клик вне нашей панели (в других приложениях).
    func handleOutsideClick(_ p: NSPoint) {
        guard model.isOpen, !AppModel.shared.pinnedOpen, Date() >= AppModel.shared.holdOpenUntil else { return }
        if !model.geometry.screenRect(for: model.geometry.openSize).contains(p) { close() }
    }

    /// Клик внутри нашего окна. Возвращает true, если клик обработан.
    func handleLocalClick(_ p: NSPoint) -> Bool {
        guard !model.isOpen else { return false }
        if activeRect.contains(p) {
            open()
            return true
        }
        return false
    }

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.openWork = nil
            self?.open()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.closeWork = nil
            self?.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    func open() {
        cancelOpen()
        cancelClose()
        guard !model.isOpen else { return }
        model.isOpen = true
        panel.ignoresMouseEvents = false
        if AppModel.shared.notification != nil { AppModel.shared.dismissNotification() }
    }

    func close() {
        cancelOpen()
        cancelClose()
        guard model.isOpen else { return }
        model.isOpen = false
        AppModel.shared.pinnedOpen = false
        panel.makeFirstResponder(nil)
        handleMove(NSEvent.mouseLocation)
    }

    func refreshGeometry() {
        let g = NotchGeometry.make(for: screen, preferred: Prefs.shared.notchStyle)
        guard g != model.geometry else { return }
        model.geometry = g
        panel.setFrame(NotchController.windowFrame(for: g), display: true)
    }
}

/// Все чёлки (по одной на экран) и общий контроль мыши.
final class NotchManager {
    static let shared = NotchManager()

    private(set) var controllers: [NotchController] = []
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    func start() {
        rebuild()
        startPolling()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        Prefs.shared.$notchStyle.dropFirst()
            .merge(with: Prefs.shared.$allDisplays.dropFirst().map { _ in Prefs.shared.notchStyle })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        Prefs.shared.$lite.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startPolling() }
            .store(in: &cancellables)

        Prefs.shared.$panelScale.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.controllers.forEach { $0.refreshGeometry() } }
            }
            .store(in: &cancellables)

        // Перерисовать живые индикаторы, когда меняется то, что они показывают.
        Publishers.MergeMany(
            NowPlayingModel.shared.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            JarvisMonitor.shared.$isBusy.map { _ in () }.eraseToAnyPublisher(),
            HUDModel.shared.$current.map { _ in () }.eraseToAnyPublisher(),
            AppModel.shared.$notification.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.controllers.forEach { c in
                c.model.objectWillChange.send()
                c.handleMove(NSEvent.mouseLocation)
            }
        }
        .store(in: &cancellables)

        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            self?.mouseMoved()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] e in
            self?.mouseMoved()
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            let p = NSEvent.mouseLocation
            if e.type == .leftMouseDown { self?.mouseDownForDrag() }
            self?.controllers.forEach { $0.handleOutsideClick(p) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.endFileDrag()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            self?.endFileDrag()
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            self.mouseDownForDrag()
            let p = NSEvent.mouseLocation
            for c in self.controllers where e.window === c.panel {
                if c.handleLocalClick(p) { return nil }
            }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53, let self, self.controllers.contains(where: { $0.model.isOpen }) {   // Esc
                self.closeAll()
                return nil
            }
            return e
        }) { monitors.append(m) }
    }

    /// Запасная проверка положения курсора: события движения мыши иногда не приходят
    /// (полноэкранные приложения, курсор упёрт в край), поэтому раз в 0,2 с сверяемся сами.
    private var pollTimer: Timer?
    private var lastPoint = NSPoint(x: -1, y: -1)

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = Prefs.shared.lite ? 0.4 : 0.2
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if p != self.lastPoint || (self.fileDragging && NSEvent.pressedMouseButtons & 1 == 0) { self.mouseMoved() }
        }
        pollTimer?.tolerance = interval * 0.25
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        lastPoint = p
        if NSEvent.pressedMouseButtons & 1 != 0 {
            checkFileDrag(p)
        } else if fileDragging {
            endFileDrag()   // отпускание кнопки могло не дойти до наших мониторов
        }
        controllers.forEach { $0.handleMove(p) }
    }

    // MARK: Файл тащат к чёлке → открыть полку

    /// Перетаскивание файла видно по «drag»-буферу: его счётчик меняется, когда начинается перетаскивание.
    private var dragChangeAtDown = NSPasteboard(name: .drag).changeCount
    private var fileDragging = false

    private func mouseDownForDrag() {
        dragChangeAtDown = NSPasteboard(name: .drag).changeCount
        fileDragging = false
    }

    private func checkFileDrag(_ p: NSPoint) {
        let prefs = Prefs.shared
        guard prefs.shelfDragOpen, !WindowLayoutManager.shared.windowDragging,
              let c = controllers.first(where: { $0.screen.frame.contains(p) }) else { return }
        let g = c.model.geometry
        let f = g.screenFrame
        // Показать у верхнего края рядом с чёлкой; держать, пока курсор над полосой; увели — спрятать.
        let near = p.y >= f.maxY - 60 && abs(p.x - f.midX) <= 280
        let stay = c.model.dropActive && g.screenRect(for: g.dropSize).insetBy(dx: -80, dy: -80).contains(p)
        guard near || stay else {
            if c.model.dropActive { c.model.dropActive = false }
            return
        }
        if !fileDragging {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragChangeAtDown, let types = pb.types,
                  types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) else { return }
            fileDragging = true
            AppModel.shared.dragURLs = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        }
        let app = AppModel.shared
        if !app.fileDragActive { app.fileDragActive = true }
        if !c.model.dropActive {
            c.close()
            c.model.dropActive = true
            c.panel.ignoresMouseEvents = false
        }
    }

    /// Перетаскивание закончилось (отпустили кнопку или бросили файл на действие).
    func endFileDrag() {
        guard fileDragging || AppModel.shared.fileDragActive else { return }
        fileDragging = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            AppModel.shared.fileDragActive = false
            AppModel.shared.dragURLs = []
            let p = NSEvent.mouseLocation
            self?.controllers.forEach { c in
                c.model.dropActive = false
                c.handleMove(p)
            }
        }
    }

    func rebuild() {
        controllers.forEach { $0.teardown() }
        let screens: [NSScreen]
        if Prefs.shared.allDisplays {
            screens = NSScreen.screens
        } else {
            screens = [NSScreen.screens.first ?? NSScreen.main].compactMap { $0 }
        }
        controllers = screens.map { NotchController(screen: $0) }
    }

    /// Открыть чёлку на экране, где сейчас мышь (или на основном).
    func openOnActiveScreen() {
        let p = NSEvent.mouseLocation
        let c = controllers.first(where: { $0.screen.frame.contains(p) }) ?? controllers.first
        c?.open()
    }

    func closeAll() { controllers.forEach { $0.close() } }
}
