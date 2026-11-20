import AppKit

/// 遅延・デューティ・帯域制限・ゲート・スイープ・変調の設定 (モードレス, 即時反映)
final class DetailWindow: NSPanel, NSWindowDelegate {
    let panel: WavePanel
    var changed: (() -> Void)?
    var closed: (() -> Void)?
    private var P: WaveParams {
        get { panel.P }
        set { panel.P = newValue }
    }

    private let nDelay = NumField(0, 10_000_000, 0, 1, width: 110)
    private let nDuty = NumField(0.1, 99.9, 1, 1, width: 110)
    private let nGOn = NumField(0, 1_000_000, 1, 10, width: 110)
    private let nGOff = NumField(0, 1_000_000, 1, 10, width: 110)
    private let nSwEnd = NumField(0, 384000, 3, 100, width: 110)
    private let nSwTime = NumField(0.001, 100000, 3, 1, width: 110)
    private let nModF = NumField(0, 100000, 3, 1, width: 110)
    private let nModD = NumField(0, 100000, 1, 1, width: 110)
    private var cBand, cGate, cSweep, cSwLog, cSwPP, cMod: NSButton!
    private let cbModType = ClosurePopup.make(["AM", "FM"], width: 70)
    private let lDepthUnit = Ui.label("%")

    init(panel: WavePanel) {
        self.panel = panel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Wave\(panel.index + 1) 詳細設定"
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let save: (Bool) -> Void = { [unowned self] _ in self.save() }
        cBand = Ui.check("する (矩形/ノコギリ)", false, save)
        cGate = Ui.check("ゲート", false, save)
        cSweep = Ui.check("スイープ", false, save)
        cSwLog = Ui.check("対数", false, save)
        cSwPP = Ui.check("往復", false, save)
        cMod = Ui.check("変調", false, save)
        for n in [nDelay, nDuty, nGOn, nGOff, nSwEnd, nSwTime, nModF, nModD] { n.onChange = { [unowned self] in self.save() } }
        cbModType.onChange = { [unowned self] _ in self.save() }
        nSwEnd.onValueSet = { [unowned self] in nSwEnd.autoInc() }

        func hdr(_ s: String) -> NSTextField {
            let l = Ui.label(s); l.font = .boldSystemFont(ofSize: NSFont.systemFontSize); return l
        }
        let e = NSGridCell.emptyContentView
        let L = Ui.label
        let grid = NSGridView(views: [
            [hdr("基本"), e, e],
            [L("遅延"), nDelay, L("sample")],
            [L("デューティ"), nDuty, L("% (矩形波)")],
            [L("帯域制限"), cBand, e],
            [hdr("ゲート (断続)"), cGate, e],
            [L("ON 時間"), nGOn, L("ms")],
            [L("OFF 時間"), nGOff, L("ms")],
            [hdr("周波数スイープ"), cSweep, e],
            [L("開始"), L("= 周波数 欄"), e],
            [L("終了"), nSwEnd, L("Hz")],
            [L("時間"), nSwTime, L("秒")],
            [e, Ui.hstack([cSwLog, cSwPP], spacing: 12), e],
            [hdr("変調"), cMod, e],
            [L("方式"), cbModType, e],
            [L("変調周波数"), nModF, L("Hz")],
            [L("深さ/偏移"), nModD, lDepthUnit],
        ])
        grid.rowSpacing = 6; grid.columnSpacing = 8
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        for r in [4, 7, 12] { grid.row(at: r).topPadding = 8 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let bClose = Ui.button("閉じる", self, #selector(closeMe))
        bClose.keyEquivalent = "\u{1b}"
        let v = NSView()
        v.addSubview(grid); v.addSubview(bClose)
        bClose.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            bClose.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            bClose.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            bClose.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
        ])
        contentView = v
        loadValues()
    }

    @objc private func closeMe() { close() }
    func windowWillClose(_ notification: Notification) { closed?() }

    func loadValues() {
        nDelay.value = Double(P.delaySamples)
        nDuty.value = P.duty
        cBand.state = P.bandLimit ? .on : .off
        cGate.state = P.gate ? .on : .off
        nGOn.value = P.gateOnMs
        nGOff.value = P.gateOffMs
        cSweep.state = P.sweep ? .on : .off
        nSwEnd.value = P.sweepEndFreq
        nSwTime.value = P.sweepTimeSec
        cSwLog.state = P.sweepLog ? .on : .off
        cSwPP.state = P.sweepPingPong ? .on : .off
        cMod.state = P.mod ? .on : .off
        cbModType.selectItem(at: P.modType.rawValue)
        nModF.value = P.modFreq
        nModD.value = P.modDepth
        updateEnable()
    }

    private func updateEnable() {
        nGOn.isEnabled = cGate.state == .on; nGOff.isEnabled = cGate.state == .on
        let sw = cSweep.state == .on
        nSwEnd.isEnabled = sw; nSwTime.isEnabled = sw; cSwLog.isEnabled = sw; cSwPP.isEnabled = sw
        let md = cMod.state == .on
        cbModType.isEnabled = md; nModF.isEnabled = md; nModD.isEnabled = md
        lDepthUnit.stringValue = cbModType.indexOfSelectedItem == 1 ? "Hz (偏移)" : "% (変調度)"
    }

    private func save() {
        var p = P
        p.delaySamples = Int(nDelay.value)
        p.duty = nDuty.value
        p.bandLimit = cBand.state == .on
        p.gate = cGate.state == .on
        p.gateOnMs = nGOn.value
        p.gateOffMs = nGOff.value
        p.sweep = cSweep.state == .on
        p.sweepEndFreq = nSwEnd.value
        p.sweepTimeSec = nSwTime.value
        p.sweepLog = cSwLog.state == .on
        p.sweepPingPong = cSwPP.state == .on
        p.mod = cMod.state == .on
        p.modType = ModType(rawValue: max(0, cbModType.indexOfSelectedItem)) ?? .am
        p.modFreq = nModF.value
        p.modDepth = nModD.value
        P = p
        updateEnable()
        panel.updateState()
        changed?()
    }
}
