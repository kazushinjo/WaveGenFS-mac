// アイコン (サイン波) を作る:  swift Scripts/make_icon.swift  → Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    g.scaleBy(x: s, y: s)

    // macOS のアイコン枠 (1024 の中に 824 角・角丸 185)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(path); g.clip()
    // 背景: ごく暗い緑のグラデーション
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.05, green: 0.10, blue: 0.07, alpha: 1).cgColor,
        NSColor(srgbRed: 0.00, green: 0.02, blue: 0.01, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // 目盛り (スコープ風の赤い破線)
    let plot = body.insetBy(dx: 70, dy: 120)
    g.setStrokeColor(NSColor(srgbRed: 0.70, green: 0.15, blue: 0.15, alpha: 0.85).cgColor)
    g.setLineWidth(5)
    g.setLineDash(phase: 0, lengths: [18, 12])
    for i in 1..<4 {
        let x = plot.minX + plot.width * CGFloat(i) / 4
        g.move(to: CGPoint(x: x, y: body.minY)); g.addLine(to: CGPoint(x: x, y: body.maxY))
    }
    for y in [plot.minY, plot.maxY] {
        g.move(to: CGPoint(x: body.minX, y: y)); g.addLine(to: CGPoint(x: body.maxX, y: y))
    }
    g.strokePath()
    g.setLineDash(phase: 0, lengths: [])
    g.setStrokeColor(NSColor(srgbRed: 0.82, green: 0.13, blue: 0.13, alpha: 1).cgColor)
    g.setLineWidth(7)
    g.move(to: CGPoint(x: body.minX, y: plot.midY)); g.addLine(to: CGPoint(x: body.maxX, y: plot.midY))
    g.strokePath()

    // サイン波 (3 周期、光彩付き)
    let wave = CGMutablePath()
    let x0 = body.minX + 40, x1 = body.maxX - 40, amp = plot.height / 2
    for i in 0...800 {
        let t = CGFloat(i) / 800
        let p = CGPoint(x: x0 + (x1 - x0) * t, y: plot.midY + amp * sin(t * 2 * .pi * 3))
        i == 0 ? wave.move(to: p) : wave.addLine(to: p)
    }
    let green = NSColor(srgbRed: 0.25, green: 1.0, blue: 0.35, alpha: 1)
    g.setLineCap(.round); g.setLineJoin(.round)
    g.saveGState()
    g.setShadow(offset: .zero, blur: 32, color: green.withAlphaComponent(0.9).cgColor)
    g.addPath(wave); g.setStrokeColor(green.cgColor); g.setLineWidth(26); g.strokePath()
    g.restoreGState()
    g.addPath(wave); g.setStrokeColor(NSColor(srgbRed: 0.80, green: 1.0, blue: 0.82, alpha: 1).cgColor); g.setLineWidth(8); g.strokePath()
    g.restoreGState()

    // 縁取り
    g.addPath(path); g.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); g.setLineWidth(4); g.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: set.appendingPathComponent(name))
    }
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Resources/AppIcon.icns")
