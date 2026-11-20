import AppKit
import UniformTypeIdentifiers

/// ファイルのドロップを受ける土台のビュー
final class DropView: NSView {
    var dropped: ((URL) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let u = urls.first else { return false }
        dropped?(u)
        return true
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let fsList = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 384000]
    static let bitsNames = ["16", "24", "32 float"]
    static let bitsList = [16, 24, 32]
    /// 画面に出す波形の数 (Wave1, Wave2)。設定ファイルは Windows 版と同じ 8 系統のまま、3 以降は常に OFF
    static let usedWaves = 2

    private let settingsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WaveGenFS")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WaveGenFS.json")
    }()
    private var cfg = AppSettings()
    private var model: WaveModel!

    private let player = AudioOut()
    private let scope = ScopeView()
    private var panels: [WavePanel] = []
    private var details: [DetailWindow?] = Array(repeating: nil, count: Synth.nWaves)
    private var levelLbl: [NSTextField] = []
    private let outLbl = Ui.label("")
    private var bPlay: NSButton!, bFull: NSButton!, bHide: NSButton!
    private var chkAtt: NSButton!, chkFullVol: NSButton!, bSplit: ClosureButton!
    private let nAttN = NumField(1, 1_000_000, 2, 1, width: 100)
    private let lAttDb = Ui.label("")
    private let tbComment = NSTextField()
    private let cbFs = ClosurePopup.make(fsList.map(String.init), width: 90)
    private let cbBits = ClosurePopup.make(bitsNames, width: 90)
    private let cbCh = ClosurePopup.make(["Stereo", "Mono"], width: 85)
    private let cbDev = ClosurePopup.make([], width: 230)
    private let cbDisp = ClosurePopup.make(["Lch + Rch", "Lch", "Rch"], width: 100)
    private let nLen = NumField(0.1, 36000, 1, 1, width: 80)
    private let nLat = NumField(20, 2000, 0, 10, width: 72)
    private var devices: [AudioOut.Device] = []
    private var controlsStack: NSStackView!
    private var meterTimer: Timer?
    private var holdL: Float = 0, holdR: Float = 0, clipHold = false, clipUntil = Date()
    private var controlsHidden = false
    private var keyMonitor: Any?

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "WaveGenFS - 音声テスト信号発生器"
        w.collectionBehavior = [.fullScreenPrimary]
        super.init(window: w)
        w.delegate = self
        loadSettings()
        Ui.fs = { [unowned self] in cfg.fs }
        Ui.fftN = Ui.fftNs.contains(cfg.fftN) ? cfg.fftN : 4096
        buildUi()
        applyAll()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMeter() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        w.setFrameAutosaveName("WaveGenFSMain")
        if cfg.startFullScreen { DispatchQueue.main.async { w.toggleFullScreen(nil) } }
        applyAtt()
    }
    required init?(coder: NSCoder) { fatalError() }

    // ---------------------------------------------------------------- 設定
    private func loadSettings() {
        if let d = try? Data(contentsOf: settingsURL), let c = try? JSONDecoder().decode(AppSettings.self, from: d) { cfg = c }
        if cfg.waves == nil || cfg.waves!.count != Synth.nWaves {
            var w = [WaveParams](repeating: WaveParams(), count: Synth.nWaves)
            w[0].type = .sine; w[0].ampDb = -10
            cfg.waves = w
        }
        for i in MainWindowController.usedWaves..<Synth.nWaves { cfg.waves![i] = WaveParams() }
        model = WaveModel(cfg.waves!)
    }

    func saveSettings() {
        cfg.waves = model.waves
        cfg.fftN = Ui.fftN
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(cfg) { try? d.write(to: settingsURL) }
    }

    // ---------------------------------------------------------------- UI 構築
    private func buildUi() {
        bPlay = Ui.button("▶ 再生 (F5)", self, #selector(togglePlay))
        bPlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let bSave = Ui.button("WAV保存...", self, #selector(saveWav))
        bSave.toolTip = "WAV ファイルへ出力 (⌘E)"
        nLen.value = cfg.lengthSec
        nLen.onChange = { [unowned self] in cfg.lengthSec = nLen.value }

        cbFs.selectItem(at: max(0, MainWindowController.fsList.firstIndex(of: cfg.fs) ?? 6))
        cbBits.selectItem(at: max(0, MainWindowController.bitsList.firstIndex(of: cfg.bits) ?? 0))
        cbBits.toolTip = "WAV 保存のビット数 (Mac の再生は Core Audio の 32bit float で出力)"
        cbCh.selectItem(at: cfg.stereo ? 0 : 1)
        devices = AudioOut.devices()
        cbDev.addItems(withTitles: ["既定のデバイス"] + devices.map(\.name))
        cbDev.selectItem(at: (devices.firstIndex { $0.name == cfg.device }).map { $0 + 1 } ?? 0)
        nLat.value = Double(cfg.latencyMs)
        nLat.toolTip = "出力バッファの長さの目安 (デバイスの対応範囲に丸められます)"

        let fmtChanged: () -> Void = { [unowned self] in
            cfg.fs = MainWindowController.fsList[cbFs.indexOfSelectedItem]
            cfg.bits = MainWindowController.bitsList[cbBits.indexOfSelectedItem]
            cfg.stereo = cbCh.indexOfSelectedItem == 0
            cfg.device = cbDev.indexOfSelectedItem > 0 ? devices[cbDev.indexOfSelectedItem - 1].name : ""
            cfg.latencyMs = Int(nLat.value)
            panels.forEach { $0.load() }
            applyAll()
            if player.isPlaying { startPlay() }
        }
        cbFs.onChange = { _ in fmtChanged() }; cbBits.onChange = { _ in fmtChanged() }
        cbCh.onChange = { _ in fmtChanged() }; cbDev.onChange = { _ in fmtChanged() }
        nLat.onChange = fmtChanged

        // 出力減衰 (設定振幅の 1/N)
        let att = ClosureButton(title: "出力 1/N", target: nil, action: nil)
        att.setButtonType(.pushOnPushOff)
        att.bezelStyle = .rounded
        att.state = cfg.attOn ? .on : .off
        att.onClick = { [unowned self] b in cfg.attOn = b.state == .on; applyAtt() }
        att.toolTip = "押すと出力を設定振幅の 1/N に減衰 (再生・波形表示・WAV保存に適用)"
        chkAtt = att
        nAttN.value = cfg.attN
        nAttN.onChange = { [unowned self] in cfg.attN = nAttN.value; applyAtt() }
        chkFullVol = Ui.check("Volume最大", cfg.fullVolume) { [unowned self] on in cfg.fullVolume = on; if player.isPlaying { startPlay() } }
        chkFullVol.toolTip = "再生中だけ出力デバイスの音量を最大にする (停止で元に戻す)"

        let bLoad = Ui.button("設定読込...", self, #selector(openParamFile))
        bLoad.toolTip = "設定ファイルを開く (⌘O)  ※ウインドウへのドロップでも可"
        let bSaveP = Ui.button("設定保存...", self, #selector(saveParamFile))
        bSaveP.toolTip = "現在の全設定をコメント付きで保存 (⌘S)"
        tbComment.placeholderString = "設定ファイル用コメント"
        tbComment.stringValue = cfg.comment
        tbComment.widthAnchor.constraint(equalToConstant: 260).isActive = true
        tbComment.target = self; tbComment.action = #selector(commentChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(commentChanged), name: NSControl.textDidChangeNotification, object: tbComment)

        bFull = Ui.button("全画面 (F11)", self, #selector(toggleFull))
        bHide = Ui.button("波形のみ (F12)", self, #selector(toggleHide))

        let L = Ui.label
        let row1 = Ui.hstack([bPlay, bSave, nLen, L("秒"), spacer(10), L("Fs"), cbFs, L("bit"), cbBits, cbCh,
                              spacer(10), L("出力"), cbDev, L("遅延"), nLat, L("ms"), chkFullVol])
        let row2 = Ui.hstack([chkAtt, nAttN, lAttDb, spacer(10), bLoad, bSaveP, tbComment, spacer(10), bFull, bHide])

        for i in 0..<Synth.nWaves {
            let p = WavePanel(index: i, model: model)
            p.changed = { [unowned self] in applyAll(i) }
            p.detailRequested = { [unowned self] pn in showDetail(pn) }
            p.multipleRequested = { [unowned self] pn, x in
                let b = pn.index < 4 ? 0 : 4
                model.waves[pn.index].freq = model.waves[b].freq * Double(x)
                pn.load()
                applyAll(pn.index)
            }
            panels.append(p)
        }
        let panelRow = Ui.hstack(Array(panels[0..<MainWindowController.usedWaves]), spacing: 8)
        panelRow.alignment = .top

        cbDisp.selectItem(at: min(max(cfg.dispCh, 0), 2))
        cbDisp.onChange = { [unowned self] i in cfg.dispCh = i; scope.dispCh = i; updateSplit() }
        bSplit = ClosureButton(title: "L/R分離", target: nil, action: nil)
        bSplit.setButtonType(.pushOnPushOff)
        bSplit.bezelStyle = .rounded
        bSplit.state = cfg.splitLR ? .on : .off
        bSplit.onClick = { [unowned self] b in cfg.splitLR = b.state == .on; updateSplit() }
        bSplit.toolTip = "L と R を上下に分けて表示 (表示ch が Lch + Rch・Stereo のとき) (⌘D)"
        var lv: [NSView] = [L("表示ch"), cbDisp, bSplit, spacer(10), L("Level (dBFS rms)")]
        for i in 0..<Synth.nWaves {
            if i >= MainWindowController.usedWaves { levelLbl.append(NSTextField(labelWithString: "")); continue }
            lv.append(L("\(i + 1):"))
            let l = NSTextField(labelWithString: "")
            l.alignment = .right
            l.isBordered = true; l.drawsBackground = true; l.backgroundColor = .textBackgroundColor
            l.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            l.widthAnchor.constraint(equalToConstant: 58).isActive = true
            levelLbl.append(l)
            lv.append(l)
        }
        lv.append(spacer(10)); lv.append(outLbl)
        let levelRow = Ui.hstack(lv, spacing: 4)

        scope.spanIdx = min(max(cfg.spanIdx, 0), ScopeView.spans.count - 1)
        scope.yZoomIdx = min(max(cfg.yZoomIdx, 0), ScopeView.yZooms.count - 1)
        scope.dispCh = cbDisp.indexOfSelectedItem
        scope.split = cfg.splitLR
        scope.spanChanged = { [unowned self] in cfg.spanIdx = scope.spanIdx; cfg.yZoomIdx = scope.yZoomIdx; updateScope() }
        scope.doubleClicked = { [unowned self] in
            if !isFullScreen && !controlsHidden { setControlsHidden(true); if !isFullScreen { window?.toggleFullScreen(nil) } }
            else { setControlsHidden(false); if isFullScreen { window?.toggleFullScreen(nil) } }
        }
        scope.toolTip = "スクロール: 時間軸  ⌘+スクロール: 振幅軸  ダブルクリック: 全画面波形表示\nF11: 全画面  F12: 波形のみ  Esc: 戻る  F5: 再生/停止"

        controlsStack = NSStackView(views: [row1, row2, panelRow, levelRow])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 6
        controlsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
        controlsStack.setHuggingPriority(.required, for: .vertical)

        let root = DropView()
        root.dropped = { [unowned self] u in loadParamFile(u) }
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        scope.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controlsStack); root.addSubview(scope)
        let scopeTop = scope.topAnchor.constraint(equalTo: controlsStack.bottomAnchor)
        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: root.topAnchor),
            controlsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scopeTop,
            scope.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scope.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scope.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scope.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window?.contentView = root
        // 初期サイズ: 操作部が全部見える幅 + 波形 340
        root.layoutSubtreeIfNeeded()
        let fit = controlsStack.fittingSize
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1600, height: 1000)
        window?.setContentSize(NSSize(width: min(vis.width - 40, max(900, fit.width)), height: min(vis.height - 40, fit.height + 340)))
        window?.contentMinSize = NSSize(width: 400, height: 300)
        window?.center()
    }

    private func spacer(_ w: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    @objc func toggleSplit() {
        bSplit.state = bSplit.state == .on ? .off : .on
        cfg.splitLR = bSplit.state == .on
        updateSplit()
    }

    /// L/R分離ボタンの状態を表示に反映 (Mono・単独ch表示では使えない)
    private func updateSplit() {
        bSplit.isEnabled = cfg.stereo && cfg.dispCh == 0
        bSplit.bezelColor = cfg.splitLR && bSplit.isEnabled ? NSColor(srgbRed: 1, green: 220 / 255.0, blue: 140 / 255.0, alpha: 1) : nil
        scope.split = cfg.splitLR
        scope.needsDisplay = true
    }

    @objc private func commentChanged() { cfg.comment = String(tbComment.stringValue.prefix(80)) }

    // ---------------------------------------------------------------- クリップ防止
    // 各チャンネルで「全波形の最大瞬間値の合計」が 1 (100%) を超えないよう制限する。
    private let tol = 1e-9

    private func othersPeak(_ i: Int, _ c: Int) -> Double {
        let mono = !cfg.stereo
        var sum = 0.0
        for j in 0..<Synth.nWaves where j != i && model.waves[j].feeds(mono)[c] { sum += model.waves[j].peakLin }
        return sum
    }

    private func headroom(_ i: Int) -> Double {
        let f = model.waves[i].feeds(!cfg.stereo)
        var h = 1.0
        for c in 0..<2 where f[c] { h = min(h, 1 - othersPeak(i, c)) }
        return max(0, h)
    }

    private static func floorDb(_ lin: Double) -> Double { lin <= 1e-10 ? -200 : max(-200, floor(20 * log10(lin) * 10 + 1e-9) / 10) }
    private static func floor1(_ v: Double) -> Double { floor(v * 10 + 1e-9) / 10 }

    private func violates(_ c: Int) -> Bool {
        var sum = 0.0
        for j in 0..<Synth.nWaves where model.waves[j].feeds(!cfg.stereo)[c] { sum += model.waves[j].peakLin }
        return sum > 1 + tol
    }

    /// 超過していれば変更した波形 (なければ最大の波形) の振幅を下げる
    private func enforce(_ changed0: Int) {
        var changed = changed0
        var guardN = 0
        while guardN < 32 && (violates(0) || violates(1)) {
            guardN += 1
            let c = violates(0) ? 0 : 1
            let mono = !cfg.stereo
            let k: Int
            if changed >= 0 && model.waves[changed].type != .off && model.waves[changed].feeds(mono)[c] { k = changed }
            else {
                k = (0..<Synth.nWaves).filter { model.waves[$0].type != .off && model.waves[$0].feeds(mono)[c] }
                    .max { model.waves[$0].peakLin < model.waves[$1].peakLin }!
            }
            let room = headroom(k)
            var p = model.waves[k]
            if room - abs(p.offsetPct) / 100 <= 1e-6 {
                let s: Double = p.offsetPct > 0 ? 1 : p.offsetPct < 0 ? -1 : 0
                p.offsetPct = s * MainWindowController.floor1(room * 100 * 0.5)   // オフセットも入り切らない場合は半分を割り当て
            }
            p.ampDb = MainWindowController.floorDb((room - abs(p.offsetPct) / 100) / p.amFactor)
            model.waves[k] = p
            panels[k].load()
            changed = -1
        }
        // 入力欄の上限を更新
        for i in 0..<Synth.nWaves {
            let p = model.waves[i]
            let room = headroom(i)
            var ampMax = (room - abs(p.offsetPct) / 100) / p.amFactor
            var offMax = MainWindowController.floor1((room - (p.type == .off ? 0 : p.ampLin * p.amFactor)) * 100)
            if p.type == .off { ampMax = 10; offMax = 100 }
            panels[i].setLimits(min(10, ampMax), min(max(offMax, 0), 100))
        }
    }

    private func applyAll(_ changed: Int = -1) {
        enforce(changed)
        if player.isPlaying, let s = player.synth { s.params = model.waves }
        updateScope()
        updateLevels()
    }

    private func updateScope() {
        let fs = cfg.fs
        let n = Int(ceil(scope.spanMs * Double(fs) / 1000)) + 2
        let syn = Synth(fs: fs, params: model.waves, mono: !cfg.stereo, gain: attGain)
        var (L, R) = syn.render(frames: n)
        // 実際の出力と同じく ±100% でクリップした波形を表示
        var clipped = false
        for i in 0..<n {
            if L[i] > 1 { L[i] = 1; clipped = true } else if L[i] < -1 { L[i] = -1; clipped = true }
            if R[i] > 1 { R[i] = 1; clipped = true } else if R[i] < -1 { R[i] = -1; clipped = true }
        }
        scope.waveClipped = clipped
        scope.L = L; scope.R = R; scope.fs = fs; scope.mono = !cfg.stereo
        if bSplit != nil { updateSplit() }
        scope.overlay = model.waves.enumerated().compactMap { i, p in p.summary().map { "W\(i + 1): \($0)" } }
        updateStatus()
        scope.needsDisplay = true
    }

    private func updateStatus() {
        let bits = cfg.bits == 32 ? "32f" : "\(cfg.bits)"
        var s = "\(player.isPlaying ? "▶ 再生中" : "■ 停止")  \(cfg.fs)Hz \(bits)bit \(cfg.stereo ? "Stereo" : "Mono")  \(fmtSpan(scope.spanMs))/画面"
        if cfg.attOn { s += "  ATT 1/\(T(cfg.attN, 2))" }
        if scope.yZoomIdx > 0 { s += " ×\(G(ScopeView.yZooms[scope.yZoomIdx]))" }
        if player.isPlaying && abs(player.deviceRate - Double(cfg.fs)) > 0.5 && player.deviceRate > 0 {
            s += "  (デバイス \(G(player.deviceRate))Hz に変換)"
        }
        if scope.clip { s += "  CLIP!" }
        scope.status = s
    }

    private func fmtSpan(_ ms: Double) -> String { ms >= 1000 ? "\(G(ms / 1000))s" : "\(G(ms))ms" }

    private func updateLevels() {
        let fs = cfg.fs, n = max(4096, fs / 4)
        for i in 0..<Synth.nWaves {
            var p = model.waves[i]
            if p.type == .off { levelLbl[i].stringValue = ""; continue }
            p.delaySamples = 0
            var ps = [WaveParams](repeating: WaveParams(), count: Synth.nWaves)
            ps[i] = p
            let (L, _) = Synth(fs: fs, params: ps, mono: true).render(frames: n)
            var sum = 0.0
            for v in L { sum += Double(v) * Double(v) }
            let rms = (sum / Double(n)).squareRoot()
            levelLbl[i].stringValue = rms > 0 ? F(20 * log10(rms), 2) : "-∞"
        }
    }

    private func updateMeter() {
        guard player.isPlaying, let s = player.synth else { outLbl.stringValue = ""; return }
        let (pl, pr) = s.peaks
        holdL = max(pl, holdL * 0.8)
        holdR = max(pr, holdR * 0.8)
        if pl > 1 || pr > 1 { clipHold = true; clipUntil = Date().addingTimeInterval(1.5) }
        if clipHold && Date() > clipUntil { clipHold = false }
        func db(_ v: Float) -> String { v > 0 ? F(20 * log10(Double(v)), 1) : "-∞" }
        outLbl.stringValue = "出力ピーク L \(db(holdL))  R \(db(holdR)) dBFS" + (clipHold ? "  CLIP!" : "")
        outLbl.textColor = clipHold ? .systemRed : .labelColor
        if scope.clip != clipHold { scope.clip = clipHold; updateStatus(); scope.needsDisplay = true }
    }

    // ---------------------------------------------------------------- 再生
    @objc func togglePlay() {
        if player.isPlaying { stopPlay() } else { startPlay() }
    }

    private func startPlay() {
        do {
            player.stop()
            let syn = Synth(fs: cfg.fs, params: model.waves, mono: !cfg.stereo, gain: attGain)
            let dev = cbDev.indexOfSelectedItem > 0 ? devices[cbDev.indexOfSelectedItem - 1].id : nil
            try player.start(synth: syn, device: dev, latencyMs: cfg.latencyMs, fullVolume: cfg.fullVolume)
            bPlay.title = "■ 停止 (F5)"
        } catch {
            player.stop()
            bPlay.title = "▶ 再生 (F5)"
            alert("再生エラー", error.localizedDescription)
        }
        updateStatus(); scope.needsDisplay = true
    }

    private func stopPlay() {
        player.stop()
        bPlay.title = "▶ 再生 (F5)"
        updateStatus(); scope.needsDisplay = true
    }

    private func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = msg; a.alertStyle = .warning
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    @objc func saveWav() {
        let dlg = NSSavePanel()
        dlg.allowedContentTypes = [UTType.wav]
        dlg.nameFieldStringValue = "WAVE.wav"
        if FileManager.default.fileExists(atPath: cfg.lastWavDir) { dlg.directoryURL = URL(fileURLWithPath: cfg.lastWavDir) }
        guard let w = window else { return }
        dlg.beginSheetModal(for: w) { [unowned self] r in
            guard r == .OK, let url = dlg.url else { return }
            NSCursor.operationNotAllowed.push()
            defer { NSCursor.pop() }
            do {
                try Synth.writeWav(url: url, params: model.waves, fs: cfg.fs, bits: cfg.bits, ch: cfg.stereo ? 2 : 1,
                                   seconds: cfg.lengthSec, gain: attGain)
                cfg.lastWavDir = url.deletingLastPathComponent().path
            } catch {
                alert("保存エラー", error.localizedDescription)
            }
        }
    }

    // ---------------------------------------------------------------- 出力減衰
    private var attGain: Float { cfg.attOn ? Float(1.0 / max(1, cfg.attN)) : 1 }

    private func applyAtt() {
        lAttDb.stringValue = "(\(T(-20 * log10(max(1, cfg.attN)), 2))dB)"
        lAttDb.textColor = cfg.attOn ? NSColor(srgbRed: 0, green: 90 / 255.0, blue: 200 / 255.0, alpha: 1) : .disabledControlTextColor
        chkAtt.state = cfg.attOn ? .on : .off
        chkAtt.bezelColor = cfg.attOn ? NSColor(srgbRed: 1, green: 220 / 255.0, blue: 140 / 255.0, alpha: 1) : nil
        chkAtt.title = cfg.attOn ? "出力 1/N : ON" : "出力 1/N : OFF"
        if player.isPlaying, let s = player.synth { s.gain = attGain }
        updateScope()
    }

    // ---------------------------------------------------------------- 設定ファイル
    @objc func openParamFile() {
        let dlg = NSOpenPanel()
        dlg.title = "設定ファイルを開く"
        dlg.allowsOtherFileTypes = true
        if FileManager.default.fileExists(atPath: cfg.lastParamDir) { dlg.directoryURL = URL(fileURLWithPath: cfg.lastParamDir) }
        guard let w = window else { return }
        dlg.beginSheetModal(for: w) { [unowned self] r in
            if r == .OK, let u = dlg.url { loadParamFile(u) }
        }
    }

    func loadParamFile(_ url: URL) {
        do {
            let pf = try JSONDecoder().decode(ParamFile.self, from: Data(contentsOf: url))
            guard let ws = pf.waves, ws.count == Synth.nWaves else {
                throw NSError(domain: "WaveGenFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "WaveGenFS の設定ファイルではありません"])
            }
            let wasPlaying = player.isPlaying
            if wasPlaying { stopPlay() }
            let dropped = (MainWindowController.usedWaves..<Synth.nWaves).filter { (ws[$0]?.type ?? .off) != .off }
            for i in 0..<Synth.nWaves {
                model.waves[i] = i < MainWindowController.usedWaves ? ws[i] ?? WaveParams() : WaveParams()
                details[i]?.close()
            }
            cfg.fftN = Ui.fftNs.contains(pf.fftN) ? pf.fftN : 4096
            Ui.fftN = cfg.fftN
            cfg.attN = pf.attN; cfg.attOn = pf.attOn
            nAttN.value = pf.attN
            nLen.value = pf.lengthSec; cfg.lengthSec = nLen.value
            tbComment.stringValue = pf.comment; cfg.comment = pf.comment
            if let fi = MainWindowController.fsList.firstIndex(of: pf.fs) { cfg.fs = pf.fs; cbFs.selectItem(at: fi) }
            if let bi = MainWindowController.bitsList.firstIndex(of: pf.bits) { cfg.bits = pf.bits; cbBits.selectItem(at: bi) }
            cfg.stereo = pf.stereo
            cbCh.selectItem(at: pf.stereo ? 0 : 1)
            panels.forEach { $0.load() }
            applyAll()
            applyAtt()
            cfg.lastParamDir = url.deletingLastPathComponent().path
            window?.title = "WaveGenFS - \(url.lastPathComponent)"
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if wasPlaying { startPlay() }
            if !dropped.isEmpty {
                alert("Wave1・2 だけ読み込みました", "このファイルの " + dropped.map { "Wave\($0 + 1)" }.joined(separator: ", ") +
                      " は Mac 版では使わないため OFF にしました。")
            }
        } catch {
            alert("設定読込エラー", error.localizedDescription)
        }
    }

    @objc func saveParamFile() {
        let dlg = NSSavePanel()
        dlg.title = "設定ファイルの保存"
        dlg.allowedContentTypes = [UTType(filenameExtension: "wgfs") ?? .json]
        dlg.nameFieldStringValue = "WAVE.wgfs"
        if FileManager.default.fileExists(atPath: cfg.lastParamDir) { dlg.directoryURL = URL(fileURLWithPath: cfg.lastParamDir) }
        guard let w = window else { return }
        dlg.beginSheetModal(for: w) { [unowned self] r in
            guard r == .OK, let url = dlg.url else { return }
            var pf = ParamFile()
            pf.comment = cfg.comment; pf.fs = cfg.fs; pf.bits = cfg.bits; pf.stereo = cfg.stereo; pf.lengthSec = cfg.lengthSec
            pf.fftN = Ui.fftN; pf.attOn = cfg.attOn; pf.attN = cfg.attN; pf.waves = model.waves
            do {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
                try enc.encode(pf).write(to: url)
                cfg.lastParamDir = url.deletingLastPathComponent().path
                window?.title = "WaveGenFS - \(url.lastPathComponent)"
            } catch {
                alert("保存エラー", error.localizedDescription)
            }
        }
    }

    private func showDetail(_ p: WavePanel) {
        if let d = details[p.index] { d.makeKeyAndOrderFront(nil); return }
        let d = DetailWindow(panel: p)
        let idx = p.index
        d.changed = { [unowned self] in applyAll(idx) }
        d.closed = { [unowned self] in details[idx] = nil }
        details[idx] = d
        if let w = window {
            let f = w.frame
            d.setFrameTopLeftPoint(NSPoint(x: f.midX - d.frame.width / 2, y: f.maxY - 80))
        }
        d.makeKeyAndOrderFront(nil)
    }

    // ---------------------------------------------------------------- 全画面
    @objc func toggleFull() { window?.toggleFullScreen(nil) }
    @objc func toggleHide() { setControlsHidden(!controlsHidden) }

    func windowDidEnterFullScreen(_ notification: Notification) { bFull.title = "全画面解除 (F11)" }
    func windowDidExitFullScreen(_ notification: Notification) { bFull.title = "全画面 (F11)" }

    private func setControlsHidden(_ hide: Bool) {
        controlsHidden = hide
        controlsStack.isHidden = hide
        bHide.title = hide ? "操作部表示 (F12)" : "波形のみ (F12)"
        if hide { window?.makeFirstResponder(scope) }
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(e.keyCode) {
        case 96 where mods.isEmpty: togglePlay(); return nil          // F5
        case 103 where mods.isEmpty: toggleFull(); return nil         // F11
        case 111 where mods.isEmpty: toggleHide(); return nil         // F12
        case 53 where isFullScreen || controlsHidden:                 // Esc
            setControlsHidden(false)
            if isFullScreen { window?.toggleFullScreen(nil) }
            return nil
        default: return e
        }
    }

    func shutdown() {
        player.stop()
        meterTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        saveSettings()
    }
}
