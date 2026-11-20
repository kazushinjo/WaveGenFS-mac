import AppKit

/// 8系統の波形パラメータ (画面全体で共有)
final class WaveModel {
    var waves: [WaveParams]
    init(_ w: [WaveParams]) { waves = w }
}

/// 1系統の基本設定パネル。詳細はボタンから DetailWindow。
final class WavePanel: NSView {
    let index: Int
    let model: WaveModel
    var P: WaveParams {
        get { model.waves[index] }
        set { model.waves[index] = newValue }
    }
    var changed: (() -> Void)?
    var detailRequested: ((WavePanel) -> Void)?
    /// (このパネル, 倍数) : Wave1/Wave5 の倍数に設定
    var multipleRequested: ((WavePanel, Int) -> Void)?

    private let cbType = ClosurePopup.make(WaveParams.typeNames, width: 140)
    private let cbCh = ClosurePopup.make(WaveParams.chNames, width: 74)
    private let nFreq = NumField(0, 10_000_000, 4, 10, width: 118)
    private let nAmp = NumField(-200, 20, 1, 1, width: 118)
    private let nOff = NumField(-100, 100, 1, 1, width: 118)
    private let nPhase = NumField(-360, 360, 1, 5, width: 118)
    private let lFreqUnit = UnitLink(), lAmpUnit = UnitLink()
    private let bDetail = ClosureButton(title: "詳細...", target: nil, action: nil)
    private var labels: [NSTextField] = []
    private var ampMaxLin = 10.0, offMaxPct = 100.0
    private var fitItem: NSMenuItem!
    private var fftMenu: NSMenu!
    private var mulItem: NSMenuItem?

    static let valueMax = 32767.0

    /// 倍数設定の基準の波形 (Wave1)。基準自身は nil
    static func multipleBase(_ i: Int) -> Int? {
        if i == 0 { return nil }
        return 0
    }

    init(index: Int, model: WaveModel) {
        self.index = index; self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        bDetail.bezelStyle = .rounded
        bDetail.controlSize = .regular
        func L(_ s: String) -> NSTextField { let l = Ui.label(s); labels.append(l); return l }
        let unitPct = L("%"), unitDeg = L("°")
        let grid = NSGridView(views: [
            [L("波形"), cbType, NSGridCell.emptyContentView],
            [L("周波数"), nFreq, lFreqUnit],
            [L("振幅"), nAmp, lAmpUnit],
            [L("オフセット"), nOff, unitPct],
            [L("位相"), nPhase, unitDeg],
            [L("出力"), Ui.hstack([cbCh, bDetail], spacing: 4), NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 5; grid.columnSpacing = 4
        grid.cell(atColumnIndex: 1, rowIndex: 0).row?.mergeCells(in: NSRange(location: 1, length: 2))
        grid.cell(atColumnIndex: 1, rowIndex: 5).row?.mergeCells(in: NSRange(location: 1, length: 2))
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        grid.column(at: 2).width = 62
        // 見出し + 角丸の背景。大きさはすべて中身 (grid) から決まる
        let titleLabel = Ui.label("Wave\(index + 1)")
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let bg = NSBox()
        bg.boxType = .custom
        bg.cornerRadius = 6
        bg.borderWidth = 1
        bg.borderColor = .separatorColor
        bg.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        bg.titlePosition = .noTitle
        for v in [titleLabel, bg, grid] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bg.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.topAnchor.constraint(equalTo: bg.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
            grid.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
        ])
        // 幅は中身の幅に固定 (並べる列が広いと余りの幅で引き伸ばされるため)
        widthAnchor.constraint(equalToConstant: ceil(grid.fittingSize.width) + 16).isActive = true

        // 単位: クリックで順に切替、右クリックでメニュー
        lFreqUnit.toolTip = "クリック: Hz / Sa(周期サンプル数) 切替"
        lAmpUnit.toolTip = "クリック: dB / 値(32767max) / % 切替\n値・% で負の値にすると極性反転"
        lFreqUnit.onClick = { [unowned self] in P.freqUnit = P.freqUnit == "Sa" ? "Hz" : "Sa"; load() }
        lAmpUnit.onClick = { [unowned self] in
            P.ampUnit = P.ampUnit == "dB" ? "value" : P.ampUnit == "value" ? "percent" : "dB"; load()
        }
        buildMenus()

        cbType.onChange = { [unowned self] i in P.type = WaveType(rawValue: i) ?? .off; fire() }
        cbCh.onChange = { [unowned self] i in P.ch = OutCh(rawValue: i) ?? .lr; fire() }
        nFreq.onValueSet = { [unowned self] in nFreq.autoInc() }
        nFreq.onChange = { [unowned self] in
            let v = nFreq.value
            P.freq = P.freqUnit == "Sa" ? (v == 0 ? 0 : Double(Ui.fs()) / v) : v
            load(); fire()
        }
        nAmp.onChange = { [unowned self] in
            let v = nAmp.value
            if P.ampUnit == "dB" { P.ampDb = v } else {
                let lin = abs(v) / (P.ampUnit == "value" ? WavePanel.valueMax : 100)
                P.invert = v < 0
                P.ampDb = lin <= 0 ? -200 : 20 * log10(lin)
            }
            fire()
        }
        nOff.onChange = { [unowned self] in P.offsetPct = nOff.value; fire() }
        nPhase.onChange = { [unowned self] in P.phaseDeg = nPhase.value; fire() }
        bDetail.onClick = { [unowned self] _ in detailRequested?(self) }
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildMenus() {
        let m = NSMenu()
        fitItem = ClosureMenuItem("FFT用に最適化") { [unowned self] in
            let bin = Double(Ui.fs()) / Double(Ui.fftN)
            let k = max(1, (P.freq / bin).rounded(.toNearestOrEven))
            P.freq = k * bin
            load(); fire()
        }
        m.addItem(fitItem)
        let nItem = NSMenuItem(title: "  FFTサンプル数", action: nil, keyEquivalent: "")
        fftMenu = NSMenu()
        for n in Ui.fftNs { fftMenu.addItem(ClosureMenuItem("\(n)") { Ui.fftN = n }) }
        nItem.submenu = fftMenu
        m.addItem(nItem)
        if index != 0 {
            // 基準 (Wave1 か Wave5) は表示数で変わるので、開くたびに見出しを直す
            let mul = NSMenuItem(title: "Wave1 の倍数", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            for x in [2, 3, 4, 5, 6, 8, 10] {
                sm.addItem(ClosureMenuItem("x\(x)") { [unowned self] in multipleRequested?(self, x) })
            }
            mul.submenu = sm
            m.addItem(mul)
            mulItem = mul
        }
        m.delegate = self
        nFreq.menu = m

        let um = NSMenu()
        for (u, t) in [("Hz", "Hz"), ("Sa", "Sample数 (周期)")] {
            um.addItem(ClosureMenuItem(t) { [unowned self] in P.freqUnit = u; load() })
        }
        lFreqUnit.menu = um
        let am = NSMenu()
        for (u, t) in [("dB", "dB  (0max)"), ("value", "数値 (32767max)"), ("percent", "%  (100max)")] {
            am.addItem(ClosureMenuItem(t) { [unowned self] in P.ampUnit = u; load() })
        }
        lAmpUnit.menu = am
    }

    private func fire() { updateState(); changed?() }

    /// モデルの値を表示に反映 (単位・上限も含む)
    func load() {
        cbType.selectItem(at: P.type.rawValue)
        cbCh.selectItem(at: P.ch.rawValue)

        let sa = P.freqUnit == "Sa"
        lFreqUnit.text = sa ? "Sa" : "Hz"
        nFreq.decimals = sa ? 3 : 4
        nFreq.value = sa ? (P.freq == 0 ? 0 : Double(Ui.fs()) / P.freq) : P.freq
        let over = P.freq > Double(Ui.fs()) / 2   // ナイキスト周波数超え (折り返し) の警告
        nFreq.warn = over && !P.isNoise

        applyAmpLimits()
        nOff.value = P.offsetPct
        nPhase.value = P.phaseDeg
        updateState()
    }

    private static func floorDec(_ v: Double, _ dec: Int) -> Double { let s = pow(10, Double(dec)); return floor(v * s + 1e-9) / s }

    private func applyAmpLimits() {
        let sign: Double = P.invert ? -1 : 1, lin = pow(10, P.ampDb / 20)
        switch P.ampUnit {
        case "value":
            lAmpUnit.text = "値"
            nAmp.decimals = 1; nAmp.increment = 1
            let mx = WavePanel.floorDec(ampMaxLin * WavePanel.valueMax, 1)
            nAmp.minimum = -mx; nAmp.maximum = mx
            nAmp.value = sign * lin * WavePanel.valueMax
        case "percent":
            lAmpUnit.text = "%"
            nAmp.decimals = 2; nAmp.increment = 1
            let mx = WavePanel.floorDec(ampMaxLin * 100, 2)
            nAmp.minimum = -mx; nAmp.maximum = mx
            nAmp.value = sign * lin * 100
        default:
            lAmpUnit.text = P.invert ? "dB(反転)" : "dB"
            nAmp.decimals = 1; nAmp.increment = 1
            nAmp.minimum = -200
            nAmp.maximum = max(-200, ampMaxLin <= 1e-10 ? -200 : WavePanel.floorDec(20 * log10(ampMaxLin), 1))
            nAmp.value = P.ampDb
        }
        nOff.maximum = offMaxPct; nOff.minimum = -offMaxPct
    }

    /// クリップしない上限を設定 (振幅の線形上限, オフセット絶対値上限 %)
    func setLimits(_ ampMaxLinear: Double, _ offMaxPercent: Double) {
        ampMaxLin = max(0, ampMaxLinear)
        offMaxPct = max(0, offMaxPercent)
        applyAmpLimits()
        // 表示の丸め/制限で値が変わった場合のみモデルへ戻す
        let shown = nAmp.value
        let curShown: Double
        switch P.ampUnit {
        case "value": curShown = (P.invert ? -1 : 1) * pow(10, P.ampDb / 20) * WavePanel.valueMax
        case "percent": curShown = (P.invert ? -1 : 1) * pow(10, P.ampDb / 20) * 100
        default: curShown = P.ampDb
        }
        if abs(shown - curShown) > pow(10, -Double(nAmp.decimals)) {
            if P.ampUnit == "dB" { P.ampDb = shown } else {
                let lin = abs(shown) / (P.ampUnit == "value" ? WavePanel.valueMax : 100)
                P.ampDb = lin <= 0 ? -200 : 20 * log10(lin)
            }
        }
        if abs(P.offsetPct) > offMaxPct + 1e-9 { P.offsetPct = nOff.value }
    }

    func updateState() {
        let on = P.type != .off
        nFreq.isEnabled = on && !P.isNoise; nPhase.isEnabled = on && !P.isNoise
        nAmp.isEnabled = on; nOff.isEnabled = on; cbCh.isEnabled = on
        var tags: [String] = []
        if P.sweep { tags.append("Sw") }
        if P.mod { tags.append(P.modType == .am ? "AM" : "FM") }
        if P.gate { tags.append("G") }
        if P.delaySamples != 0 { tags.append("D") }
        bDetail.title = tags.isEmpty ? "詳細..." : "詳細[\(tags.joined(separator: ","))]"
        for l in labels { l.textColor = on ? .labelColor : .disabledControlTextColor }
    }
}

extension WavePanel: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        fitItem.title = "FFT用に最適化  (\(Ui.fftN)点: \(T(Double(Ui.fs()) / Double(Ui.fftN), 5))Hz の整数倍)"
        for it in fftMenu.items { it.state = it.title == "\(Ui.fftN)" ? .on : .off }
        if let mul = mulItem {
            let b = WavePanel.multipleBase(index)
            mul.isHidden = b == nil
            if let b = b { mul.title = "Wave\(b + 1) の倍数" }
        }
    }
}
