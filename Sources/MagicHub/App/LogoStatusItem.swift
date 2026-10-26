import AppKit
import Combine

/// Значок Magic Hub в меню-баре: матовое чёрное сердечко на сером круге с размытыми краями.
/// Пока активен «Не спать» — выбранный значок выбранного цвета.
final class LogoStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть Magic Hub", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Проверить обновления", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из Magic Hub", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.toolTip = "Magic Hub"
        updateImage()

        // Значок «Не спать» виден в меню-баре, даже если сердечко скрыто в настройках.
        Publishers.CombineLatest(Prefs.shared.$showMenuBarIcon, AwakeController.shared.$isActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] show, awake in self?.item.isVisible = show || awake }
            .store(in: &cancellables)
        Publishers.CombineLatest3(AwakeController.shared.$isActive, Prefs.shared.$awakeIcon, Prefs.shared.$awakeColor)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateImage() }
            .store(in: &cancellables)
    }

    private func updateImage() {
        if AwakeController.shared.isActive {
            let symbol = Prefs.shared.awakeIcon
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Не спать") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                var image = base.withSymbolConfiguration(config) ?? base
                if let color = Self.nsColor(Prefs.shared.awakeColor) {
                    image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
                    image.isTemplate = false
                } else {
                    image.isTemplate = true
                }
                item.button?.image = image
                return
            }
        }
        item.button?.image = Self.logo(size: 18)
    }

    private static func nsColor(_ name: String) -> NSColor? {
        switch name {
        case "orange": return NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)
        case "green": return NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        case "blue": return NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
        case "purple": return NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)
        case "pink": return NSColor(red: 1, green: 0.39, blue: 0.51, alpha: 1)
        default: return nil
        }
    }

    /// Рисует логотип программно (тот же рисунок, что у иконки приложения).
    static func logo(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let colors = [
                NSColor(white: 0.66, alpha: 1).cgColor,
                NSColor(white: 0.56, alpha: 1).cgColor,
                NSColor(white: 0.56, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) {
                let c = CGPoint(x: rect.midX, y: rect.midY)
                ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width / 2, options: [])
            }
            heartPath(in: rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.25)).fill(with: NSColor(white: 0.08, alpha: 1))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Сердечко в прямоугольнике (координаты с осью Y вниз).
    static func heartPath(in r: CGRect) -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + r.width * x / 24, y: r.minY + r.height * y / 24) }
        let path = NSBezierPath()
        path.move(to: p(12, 21))
        path.curve(to: p(2.5, 10), controlPoint1: p(6, 16.8), controlPoint2: p(2.5, 13.8))
        path.curve(to: p(7.5, 4), controlPoint1: p(2.5, 6.6), controlPoint2: p(4.8, 4))
        path.curve(to: p(12, 7), controlPoint1: p(9.6, 4), controlPoint2: p(11.1, 5.4))
        path.curve(to: p(16.5, 4), controlPoint1: p(12.9, 5.4), controlPoint2: p(14.4, 4))
        path.curve(to: p(21.5, 10), controlPoint1: p(19.2, 4), controlPoint2: p(21.5, 6.6))
        path.curve(to: p(12, 21), controlPoint1: p(21.5, 13.8), controlPoint2: p(18, 16.8))
        path.close()
        return path
    }

    @objc private func openPanel() { AppModel.shared.open() }
    @objc private func openSettings() { AppModel.shared.open(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkUpdates() {
        Updater.shared.check(manual: true)
        AppModel.shared.open(.settings)
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
