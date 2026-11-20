import Foundation

// Windows 版 (C#) と同じ数値で JSON に保存する (*.wgfs の互換のため)
enum WaveType: Int, Codable, CaseIterable { case off = 0, sine, square, triangle, saw, pulse, whiteNoise, pinkNoise, pulsePM, mls }
enum OutCh: Int, Codable { case lr = 0, l, r, lmr }
enum ModType: Int, Codable { case am = 0, fm }

/// 1系統分の波形パラメータ
struct WaveParams: Codable {
    var type: WaveType = .off
    var freq: Double = 1000
    var ampDb: Double = -10
    /// 極性反転 (振幅を 値/% 単位で負にした場合)
    var invert = false
    var freqUnit = "Hz"      // Hz / Sa
    var ampUnit = "dB"       // dB / value / percent
    var offsetPct: Double = 0
    var phaseDeg: Double = 0
    var delaySamples = 0
    var ch: OutCh = .lr
    var duty: Double = 50
    var bandLimit = false

    var gate = false
    var gateOnMs: Double = 100
    var gateOffMs: Double = 100

    var sweep = false
    var sweepEndFreq: Double = 10000
    var sweepTimeSec: Double = 10
    var sweepLog = true
    var sweepPingPong = false

    var mod = false
    var modType: ModType = .am
    var modFreq: Double = 10
    var modDepth: Double = 50   // AM: %, FM: 偏移 Hz

    enum CodingKeys: String, CodingKey {
        case type = "Type", freq = "Freq", ampDb = "AmpDb", invert = "Invert", freqUnit = "FreqUnit", ampUnit = "AmpUnit"
        case offsetPct = "OffsetPct", phaseDeg = "PhaseDeg", delaySamples = "DelaySamples", ch = "Ch", duty = "Duty"
        case bandLimit = "BandLimit", gate = "Gate", gateOnMs = "GateOnMs", gateOffMs = "GateOffMs"
        case sweep = "Sweep", sweepEndFreq = "SweepEndFreq", sweepTimeSec = "SweepTimeSec", sweepLog = "SweepLog"
        case sweepPingPong = "SweepPingPong", mod = "Mod", modType = "ModType", modFreq = "ModFreq", modDepth = "ModDepth"
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        var p = WaveParams()
        func g<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        g(.type, &p.type); g(.freq, &p.freq); g(.ampDb, &p.ampDb); g(.invert, &p.invert)
        g(.freqUnit, &p.freqUnit); g(.ampUnit, &p.ampUnit); g(.offsetPct, &p.offsetPct); g(.phaseDeg, &p.phaseDeg)
        g(.delaySamples, &p.delaySamples); g(.ch, &p.ch); g(.duty, &p.duty); g(.bandLimit, &p.bandLimit)
        g(.gate, &p.gate); g(.gateOnMs, &p.gateOnMs); g(.gateOffMs, &p.gateOffMs)
        g(.sweep, &p.sweep); g(.sweepEndFreq, &p.sweepEndFreq); g(.sweepTimeSec, &p.sweepTimeSec)
        g(.sweepLog, &p.sweepLog); g(.sweepPingPong, &p.sweepPingPong)
        g(.mod, &p.mod); g(.modType, &p.modType); g(.modFreq, &p.modFreq); g(.modDepth, &p.modDepth)
        self = p
    }

    var ampLin: Double { pow(10, ampDb / 20) }
    var amFactor: Double { mod && modType == .am ? 1 + modDepth / 100 : 1 }
    /// この波形単体の最大瞬間値 (フルスケール=1)
    var peakLin: Double { type == .off ? 0 : ampLin * amFactor + abs(offsetPct) / 100 }
    /// 出力先 [L, R] (モノラル時は L のみ)
    func feeds(_ mono: Bool) -> [Bool] { mono ? [true, false] : [ch != .r, ch != .l] }
    var isNoise: Bool { type == .whiteNoise || type == .pinkNoise || type == .mls }

    static let typeNames = ["OFF", "サイン波", "矩形波", "三角波", "ノコギリ波", "パルス", "ホワイトノイズ", "ピンクノイズ", "パルス(+-)", "M系列ノイズ"]
    static let chNames = ["L+R", "L", "R", "L,-R"]

    func summary() -> String? {
        if type == .off { return nil }
        var s = "\(WaveParams.typeNames[type.rawValue]) "
        if !isNoise {
            s += sweep ? "\(WaveParams.fmtHz(freq))→\(WaveParams.fmtHz(sweepEndFreq))/\(G(sweepTimeSec))s " : "\(WaveParams.fmtHz(freq)) "
        }
        s += "\(F(ampDb, 1))dB\(invert ? "(反転)" : "") \(WaveParams.chNames[ch.rawValue])"
        if mod { s += modType == .am ? " AM \(G(modFreq))Hz \(G(modDepth))%" : " FM \(G(modFreq))Hz ±\(G(modDepth))Hz" }
        if gate { s += " Gate \(G(gateOnMs))/\(G(gateOffMs))ms" }
        return s
    }

    static func fmtHz(_ f: Double) -> String { f >= 1000 ? "\(T(f / 1000, 3))kHz" : "\(T(f, 3))Hz" }
}

// ---------------------------------------------------------------- 数値の文字列化
/// 小数 n 桁固定
func F(_ v: Double, _ n: Int) -> String { String(format: "%.\(n)f", v) }
/// 小数最大 n 桁 (末尾の 0 は省く) — C# の "0.###"
func T(_ v: Double, _ n: Int) -> String {
    var s = String(format: "%.\(n)f", v)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    if s == "-0" { s = "0" }
    return s
}
/// C# の :g 相当 (一般的な表記)
func G(_ v: Double) -> String { T(v, 6) }

/// アプリ設定 (~/Library/Application Support/WaveGenFS/WaveGenFS.json)
struct AppSettings: Codable {
    var waves: [WaveParams]? = nil
    var fs = 48000
    var bits = 16
    var stereo = true
    var device = ""
    var lengthSec: Double = 10
    var latencyMs = 120
    var spanIdx = 6
    var yZoomIdx = 0
    var dispCh = 0
    var tabIdx = 0
    var lastWavDir = ""
    var startFullScreen = false
    var fftN = 4096
    var attOn = false
    var attN: Double = 10
    var fullVolume = false
    var comment = ""
    var lastParamDir = ""

    enum CodingKeys: String, CodingKey {
        case waves = "Waves", fs = "Fs", bits = "Bits", stereo = "Stereo", device = "Device", lengthSec = "LengthSec"
        case latencyMs = "LatencyMs", spanIdx = "SpanIdx", yZoomIdx = "YZoomIdx", dispCh = "DispCh", tabIdx = "TabIdx"
        case lastWavDir = "LastWavDir", startFullScreen = "StartFullScreen", fftN = "FftN", attOn = "AttOn", attN = "AttN"
        case fullVolume = "FullVolume", comment = "Comment", lastParamDir = "LastParamDir"
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        var s = AppSettings()
        func g<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        if let w = try? c.decodeIfPresent([WaveParams].self, forKey: .waves) { s.waves = w }
        g(.fs, &s.fs); g(.bits, &s.bits); g(.stereo, &s.stereo); g(.device, &s.device); g(.lengthSec, &s.lengthSec)
        g(.latencyMs, &s.latencyMs); g(.spanIdx, &s.spanIdx); g(.yZoomIdx, &s.yZoomIdx); g(.dispCh, &s.dispCh)
        g(.tabIdx, &s.tabIdx); g(.lastWavDir, &s.lastWavDir); g(.startFullScreen, &s.startFullScreen); g(.fftN, &s.fftN)
        g(.attOn, &s.attOn); g(.attN, &s.attN); g(.fullVolume, &s.fullVolume); g(.comment, &s.comment)
        g(.lastParamDir, &s.lastParamDir)
        self = s
    }
}

/// 設定ファイル (*.wgfs) の内容 — Windows 版と共通
struct ParamFile: Codable {
    var comment = ""
    var fs = 48000
    var bits = 16
    var stereo = true
    var lengthSec: Double = 10
    var fftN = 4096
    var attOn = false
    var attN: Double = 10
    var waves: [WaveParams?]? = nil

    enum CodingKeys: String, CodingKey {
        case comment = "Comment", fs = "Fs", bits = "Bits", stereo = "Stereo", lengthSec = "LengthSec"
        case fftN = "FftN", attOn = "AttOn", attN = "AttN", waves = "Waves"
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        var s = ParamFile()
        func g<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        g(.comment, &s.comment); g(.fs, &s.fs); g(.bits, &s.bits); g(.stereo, &s.stereo); g(.lengthSec, &s.lengthSec)
        g(.fftN, &s.fftN); g(.attOn, &s.attOn); g(.attN, &s.attN)
        s.waves = try c.decodeIfPresent([WaveParams?].self, forKey: .waves)
        self = s
    }
}
