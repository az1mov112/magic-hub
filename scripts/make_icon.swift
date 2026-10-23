// Рисует иконку Magic Hub (матовое чёрное сердечко на сером круге с размытыми краями)
// и сохраняет набор PNG для iconutil.  Запуск: swift scripts/make_icon.swift build/AppIcon.iconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func heart(in r: CGRect) -> NSBezierPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + r.width * x / 24, y: r.maxY - r.height * y / 24) }
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

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Подложка в форме иконок macOS.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.225, yRadius: plate.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(white: 0.09, alpha: 1).setFill()
    platePath.fill()
    ctx.restoreGState()
    platePath.addClip()
    let bg = NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.07, alpha: 1)])
    bg?.draw(in: plate, angle: -90)

    // Серый круг с мягкими краями.
    let colors = [NSColor(white: 0.68, alpha: 1).cgColor, NSColor(white: 0.56, alpha: 1).cgColor, NSColor(white: 0.5, alpha: 0).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.58, 1]) {
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: plate.width * 0.42, options: [])
    }

    // Матовое чёрное сердечко с лёгким объёмом.
    let hr = CGRect(x: s * 0.33, y: s * 0.32, width: s * 0.34, height: s * 0.34)
    let h = heart(in: hr)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.05, alpha: 1)])?.draw(in: h, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
print("Иконка: \(outDir)")
