import AppKit

/// 波形表示。スクロール=時間軸, ⌘(または⌃)+スクロール=振幅軸。サイズに応じて文字・線幅を拡大。
final class ScopeView: NSView {
    static let spans: [Double] = [0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000]
    static let yZooms: [Double] = [1, 2, 5, 10, 20, 50, 100]

    var L: [Float] = [], R: [Float] = []
    var fs = 48000
    var spanIdx = 6
    var yZoomIdx = 0
    var dispCh = 0           // 0: L+R, 1: L, 2: R
    var split = false        // L/R 分離表示 (上段 L・下段 R)
    var mono = false
    var overlay: [String] = []
    var status = ""
    var clip = false
    var waveClipped = false  // 表示データが ±100% でクリップされている

    let backCol = NSColor.black
    let frameCol = NSColor(srgbRed: 0xD0 / 255.0, green: 0x20 / 255.0, blue: 0x20 / 255.0, alpha: 1)
    let gridCol = NSColor(srgbRed: 0x90 / 255.0, green: 0x20 / 255.0, blue: 0x20 / 255.0, alpha: 1)
    let lCol = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    let rCol = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    let textCol = NSColor(srgbRed: 0x40 / 255.0, green: 1, blue: 0x40 / 255.0, alpha: 1)

    var spanChanged: (() -> Void)?
    var doubleClicked: (() -> Void)?

    var spanMs: Double { ScopeView.spans[spanIdx] }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var scrollAcc: CGFloat = 0

    override func scrollWheel(with e: NSEvent) {
        var dy = e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas { dy /= 12 }   // トラックパッドは細かいので間引く
        if e.isDirectionInvertedFromDevice { dy = -dy }
        if e.phase == .began { scrollAcc = 0 }
        scrollAcc += dy
        guard abs(scrollAcc) >= 1 else { return }
        let d = scrollAcc > 0 ? -1 : 1
        scrollAcc = 0
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            yZoomIdx = min(max(yZoomIdx - d, 0), ScopeView.yZooms.count - 1)
        } else {
            spanIdx = min(max(spanIdx + d, 0), ScopeView.spans.count - 1)
        }
        spanChanged?()
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.clickCount == 2 { doubleClicked?() }
    }

    private static func niceStep(_ range: Double, _ maxDiv: Int) -> Double {
        let raw = range / Double(maxDiv)
        let p = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where m * p >= raw { return m * p }
        return 10 * p
    }

    private static func pct(_ y: Double, _ oneDec: Bool) -> String {
        if abs(y) < 1e-12 { return "0" }
        let s = oneDec ? String(format: "%.1f", abs(y)) : String(format: "%.0f", abs(y))
        return (y > 0 ? "+" : "-") + s + "%"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width, H = bounds.height
        backCol.setFill(); bounds.fill()
        let fsz = min(max(min(H / 42, W / 75), 8), 26) * 1.25
        let font = NSFont(name: "Menlo", size: fsz) ?? .monospacedSystemFont(ofSize: fsz, weight: .regular)
        let scale = fsz / 11
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textCol]
        func size(_ s: String) -> NSSize { (s as NSString).size(withAttributes: attrs) }
        func draw(_ s: String, _ x: CGFloat, _ y: CGFloat, _ col: NSColor? = nil) {
            var a = attrs; if let c = col { a[.foregroundColor] = c }
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
        }
        let lineH = ceil(font.ascender - font.descender + font.leading) + 1

        let span = spanMs
        let nSamp = min(L.count, Int(ceil(span * Double(fs) / 1000)) + 1)
        let showL = dispCh != 2, showR = dispCh != 1 && !mono

        // 振幅スケール: 設定倍率で収まらない場合は波形全体が入るレンジへ自動変更
        var ymax = 1.0 / ScopeView.yZooms[yZoomIdx]
        var peak = 0.0
        for i in 0..<max(0, nSamp) {
            if showL { peak = max(peak, Double(abs(L[i]))) }
            if showR && i < R.count { peak = max(peak, Double(abs(R[i]))) }
        }
        var auto = false
        if peak > ymax * 1.0001 {
            auto = true
            let need = peak * 1.05, p10 = pow(10, floor(log10(need)))
            ymax = [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map { $0 * p10 }.first { $0 >= need - 1e-12 } ?? need
            if peak <= 1.0001 { ymax = min(ymax, 1.0) }   // クリップ後の波形は ±100% に収まる
        }
        let oneDec = ymax < 0.1 || (ymax * 100).truncatingRemainder(dividingBy: 1) != 0
        let leftM = size(ScopeView.pct(-ymax * 100, oneDec)).width + 8 * scale
        let full = NSRect(x: leftM, y: 6 * scale, width: W - leftM - 14 * scale, height: H - 6 * scale - lineH - 8 * scale)
        // L/R 分離: 上段 L・下段 R (同じ振幅スケール)
        let isSplit = split && showL && showR
        let gap = isSplit ? lineH * 1.2 : 0
        var areas: [(rect: NSRect, ch: Int)] = []   // ch: 0=L, 1=R, -1=表示ch どおり
        if isSplit {
            let h = (full.height - gap) / 2
            areas = [(NSRect(x: full.minX, y: full.minY, width: full.width, height: h), 0),
                     (NSRect(x: full.minX, y: full.minY + h + gap, width: full.width, height: h), 1)]
        } else {
            areas = [(full, -1)]
        }
        if full.width < 20 || areas.contains(where: { $0.rect.height < 20 }) { return }

        let lw = max(1, scale * 0.8)
        for (ai, area) in areas.enumerated() {
            let plot = area.rect
            let isLast = ai == areas.count - 1
            func hline(_ y: CGFloat, dashed: Bool, col: NSColor, w: CGFloat) {
                g.saveGState()
                g.setStrokeColor(col.cgColor); g.setLineWidth(w)
                if dashed { g.setLineDash(phase: 0, lengths: [4 * w, 2 * w]) }
                g.move(to: CGPoint(x: plot.minX, y: y)); g.addLine(to: CGPoint(x: plot.maxX, y: y)); g.strokePath()
                g.restoreGState()
            }

            // 横線 (振幅)
            let ystep = ScopeView.niceStep(2 * ymax, plot.height > 400 ? 8 : plot.height > 160 ? 4 : 2)
            var ys: [Double] = []
            var y = -floor(ymax / ystep + 1e-9) * ystep
            while y <= ymax + 1e-9 { ys.append(y); y += ystep }
            // 上下端の値も必ず表示 (近すぎる目盛りは省く)
            ys.removeAll { abs(abs($0) - ymax) > 1e-9 && ymax - abs($0) < ystep * 0.4 }
            if !ys.contains(where: { abs($0 - ymax) < 1e-9 }) { ys.append(ymax); ys.append(-ymax) }
            for yv in ys {
                let py = plot.minY + CGFloat((ymax - yv) / (2 * ymax)) * plot.height
                if abs(yv) > 1e-12 && abs(abs(yv) - ymax) > 1e-9 { hline(py, dashed: true, col: gridCol, w: lw) }
                if abs(yv) < 1e-12 { hline(py, dashed: false, col: frameCol, w: max(1, scale)) }
                let s = ScopeView.pct(yv * 100, oneDec)
                let sz = size(s)
                draw(s, plot.minX - sz.width - 2 * scale, py - sz.height / 2)
            }
            // 縦線 (時間)。時間の数字は一番下の枠だけ
            let xstep = ScopeView.niceStep(span, max(4, Int(plot.width / (70 * scale))))
            var x = xstep
            while x < span - 1e-9 {
                let px = plot.minX + CGFloat(x / span) * plot.width
                g.saveGState()
                g.setStrokeColor(gridCol.cgColor); g.setLineWidth(lw); g.setLineDash(phase: 0, lengths: [4 * lw, 2 * lw])
                g.move(to: CGPoint(x: px, y: plot.minY)); g.addLine(to: CGPoint(x: px, y: plot.maxY)); g.strokePath()
                g.restoreGState()
                if isLast {
                    let s = T(x, 3)
                    let sz = size(s)
                    draw(s, px - sz.width / 2, plot.maxY + 2 * scale)
                }
                x += xstep
            }
            if isLast { draw("ms", plot.maxX - size("ms").width, plot.maxY + 2 * scale) }
            g.setStrokeColor(frameCol.cgColor); g.setLineWidth(max(1, scale)); g.stroke(plot)

            // 波形
            g.saveGState()
            g.clip(to: plot)
            if showR && area.ch != 0 { drawTrace(g, R, nSamp, plot, ymax, rCol, scale) }
            if showL && area.ch != 1 { drawTrace(g, L, nSamp, plot, ymax, lCol, scale) }
            g.restoreGState()

            // 凡例
            let legend = area.ch == 0 ? "L" : area.ch == 1 ? "R" : mono ? "Mono" : dispCh == 0 ? "L  R" : dispCh == 1 ? "L" : "R"
            let lsz = size(legend)
            let lx = plot.maxX - lsz.width - 6 * scale, ly = plot.maxY - lsz.height - 4 * scale
            if legend == "L  R" {
                draw("L", lx, ly, lCol)
                draw("R", lx + size("L  ").width, ly, rCol)
            } else {
                draw(legend, lx, ly, legend == "R" ? rCol : lCol)
            }
        }

        // オーバーレイ文字 (一番上の枠)
        let top = areas[0].rect, bottom = areas[areas.count - 1].rect
        var ty = top.minY + 4 * scale
        let statusW = status.isEmpty ? 0 : size(status).width
        let ovW = overlay.first.map { size($0).width } ?? 0
        if statusW > 0 && ovW + statusW + 20 * scale > top.width { ty += lineH }
        for line in overlay {
            draw(line, top.minX + 6 * scale, ty)
            ty += lineH
        }
        if !status.isEmpty {
            draw(status, top.maxX - statusW - 6 * scale, top.minY + 4 * scale, clip ? .red : nil)
        }
        var notes: [String] = []
        if auto { notes.append("自動スケール ±\(T(ymax * 100, 3))%") }
        if waveClipped { notes.append("クリップ発生 (±100%で制限)") }
        if !notes.isEmpty {
            let a = notes.joined(separator: "   ")
            draw(a, bottom.minX + 6 * scale, bottom.maxY - size(a).height - 4 * scale, waveClipped ? .red : nil)
        }
    }

    private func drawTrace(_ g: CGContext, _ d: [Float], _ n: Int, _ plot: NSRect, _ ymax: Double, _ col: NSColor, _ scale: CGFloat) {
        guard n >= 2, d.count >= n else { return }
        g.setStrokeColor(col.cgColor)
        g.setLineWidth(max(1, scale * 1.1))
        g.setLineJoin(.round)
        let span = spanMs * Double(fs) / 1000
        func Y(_ v: Double) -> CGFloat { min(max(plot.minY + CGFloat((ymax - v) / (2 * ymax)) * plot.height, -1e5), 1e5) }
        let w = Int(plot.width)
        if n <= w * 2 {
            g.setShouldAntialias(true)
            g.move(to: CGPoint(x: plot.minX, y: Y(Double(d[0]))))
            for i in 1..<n { g.addLine(to: CGPoint(x: plot.minX + CGFloat(Double(i) / span) * plot.width, y: Y(Double(d[i])))) }
            g.strokePath()
        } else {
            // 1 画素ごとに最大・最小を縦線で描く
            g.setShouldAntialias(false)
            var prevY = Y(Double(d[0]))
            for x in 0..<w {
                let a = Int(Double(x) * span / Double(w)), b = min(n, Int(Double(x + 1) * span / Double(w)) + 1)
                if a >= n { break }
                var mn = d[a], mx = d[a]
                for i in a..<b { mn = min(mn, d[i]); mx = max(mx, d[i]) }
                let y1 = Y(Double(mx)), y2 = Y(Double(mn))
                let px = plot.minX + CGFloat(x) + 0.5
                g.move(to: CGPoint(x: px, y: min(y1, prevY)))
                g.addLine(to: CGPoint(x: px, y: max(y2, prevY) + 0.5))
                prevY = (y1 + y2) / 2
            }
            g.strokePath()
            g.setShouldAntialias(true)
        }
    }
}
