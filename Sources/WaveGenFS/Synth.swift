import Foundation
import os

/// 8系統の合成器。params を差し替えると次のブロックから反映される(位相は連続)。
final class Synth {
    static let nWaves = 8
    let fs: Int
    let mono: Bool

    private let lock = OSAllocatedUnfairLock()
    private var _params: [WaveParams]
    private var _gain: Float = 1
    /// 出力全体に掛ける係数 (出力減衰 1/N)
    var gain: Float {
        get { lock.withLock { _gain } }
        set { lock.withLock { _gain = newValue } }
    }
    var params: [WaveParams] {
        get { lock.withLock { _params } }
        set { lock.withLock { _params = newValue } }
    }
    private var _peakL: Float = 0, _peakR: Float = 0
    var peaks: (Float, Float) { lock.withLock { (_peakL, _peakR) } }

    private var n: Int64 = 0
    private var phase = [Double](repeating: 0, count: nWaves)
    private var modPhase = [Double](repeating: 0, count: nWaves)

    // ノイズは全 Wave で同一の時系列
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var lfsr: UInt32 = 1
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    private var gaussSpare = 0.0, hasSpare = false
    private var nWhite = [Double](), nPink = [Double](), nMls = [Double]()

    init(fs: Int, params: [WaveParams], mono: Bool, gain: Float = 1) {
        self.fs = fs; self._params = params; self.mono = mono; self._gain = gain
    }

    private func uniform() -> Double {
        var x = rng; x ^= x << 13; x ^= x >> 7; x ^= x << 17; rng = x
        return (Double(x >> 11) + 0.5) * (1.0 / Double(UInt64(1) << 53))
    }

    /// 正規乱数 (Box-Muller)
    private func gauss() -> Double {
        if hasSpare { hasSpare = false; return gaussSpare }
        let r = (-2 * log(uniform())).squareRoot(), th = 2 * Double.pi * uniform()
        gaussSpare = r * sin(th); hasSpare = true
        return r * cos(th)
    }

    private func makeNoise(_ frames: Int, white: Bool, pink: Bool, mls: Bool) {
        if nWhite.count < frames {
            nWhite = [Double](repeating: 0, count: frames)
            nPink = nWhite; nMls = nWhite
        }
        for i in 0..<frames {
            if white || pink {
                let g = gauss()
                // ホワイト: 正規乱数を ±3.5σ でリミットし、3.5σ をフルスケールに正規化
                nWhite[i] = min(max(g, -3.5), 3.5) / 3.5
                if pink {
                    b0 = 0.99886 * b0 + g * 0.0555179
                    b1 = 0.99332 * b1 + g * 0.0750759
                    b2 = 0.96900 * b2 + g * 0.1538520
                    b3 = 0.86650 * b3 + g * 0.3104856
                    b4 = 0.55000 * b4 + g * 0.5329522
                    b5 = -0.7616 * b5 - g * 0.0168980
                    let pk = b0 + b1 + b2 + b3 + b4 + b5 + b6 + g * 0.5362
                    b6 = g * 0.115926
                    // フィルター後 σ≈3.058 → ホワイトと同じく ±3.5σ をフルスケールに
                    nPink[i] = min(max(pk / (3.5 * 3.058), -1.0), 1.0)
                }
            }
            if mls {
                // 32bit 最大長系列 (x^32 + x^22 + x^2 + x + 1), 周期 2^32-1
                let lsb = lfsr & 1
                lfsr >>= 1
                if lsb != 0 { lfsr ^= 0x80200003 }
                nMls[i] = lsb != 0 ? 1 : -1
            }
        }
    }

    @inline(__always) private static func polyBlep(_ t0: Double, _ dt: Double) -> Double {
        if dt <= 0 { return 0 }
        var t = t0
        if t < dt { t /= dt; return t + t - t * t - 1 }
        if t > 1 - dt { t = (t - 1) / dt; return t * t + t + t + 1 }
        return 0
    }

    @inline(__always) private static func frac(_ x: Double) -> Double { x - floor(x) }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int) {
        let (ps, gain) = lock.withLock { (_params, _gain) }
        L.update(repeating: 0, count: frames)
        R.update(repeating: 0, count: frames)
        let fsd = Double(fs)
        makeNoise(frames, white: ps.contains { $0.type == .whiteNoise },
                  pink: ps.contains { $0.type == .pinkNoise }, mls: ps.contains { $0.type == .mls })

        for w in 0..<min(Synth.nWaves, ps.count) {
            let p = ps[w]
            if p.type == .off { continue }
            let amp = pow(10, p.ampDb / 20) * (p.invert ? -1 : 1)
            let off = p.offsetPct / 100
            let ph0 = p.phaseDeg / 360
            let duty = min(max(p.duty / 100, 0.001), 0.999)
            let gOn = Int64(p.gateOnMs * fsd / 1000), gPer = gOn + Int64(p.gateOffMs * fsd / 1000)
            let sweepN = p.sweepTimeSec * fsd
            let sweepPer = Int64(p.sweepPingPong ? 2 * sweepN : sweepN)
            let doSweep = p.sweep && sweepPer >= 1
            let logSweep = p.sweepLog && p.freq > 0 && p.sweepEndFreq > 0
            var ph = phase[w], mph = modPhase[w]

            for i in 0..<frames {
                let t = n + Int64(i) - Int64(p.delaySamples)
                if t < 0 { continue }

                var f = p.freq
                if doSweep {
                    var pos = Double(t % sweepPer) / sweepN
                    if pos > 1 { pos = 2 - pos }
                    f = logSweep ? p.freq * pow(p.sweepEndFreq / p.freq, pos)
                                 : p.freq + (p.sweepEndFreq - p.freq) * pos
                }
                var a = amp
                if p.mod {
                    let m = sin(2 * Double.pi * mph)
                    mph = Synth.frac(mph + p.modFreq / fsd)
                    if p.modType == .fm { f += p.modDepth * m } else { a *= 1 + p.modDepth / 100 * m }
                }
                let dt = f / fsd
                let q0 = Synth.frac(ph + ph0)
                let adt = abs(dt)
                var v: Double
                switch p.type {
                case .sine: v = f == 0 ? 1 : sin(2 * Double.pi * q0)
                case .square:
                    v = q0 < duty ? 1 : -1
                    if p.bandLimit { v += Synth.polyBlep(q0, adt) - Synth.polyBlep(Synth.frac(q0 - duty), adt) }
                case .triangle:
                    v = q0 < 0.25 ? 4 * q0 : q0 < 0.75 ? 2 - 4 * q0 : 4 * q0 - 4
                case .saw:
                    let q = Synth.frac(q0 + 0.5)
                    v = 2 * q - 1
                    if p.bandLimit { v -= Synth.polyBlep(q, adt) }
                case .pulse: v = q0 < adt ? 1 : 0
                case .whiteNoise: v = nWhite[i]
                case .pinkNoise: v = nPink[i]
                case .mls: v = nMls[i]
                case .pulsePM: v = q0 < adt ? 1 : Synth.frac(q0 - 0.5) < adt ? -1 : 0
                case .off: v = 0
                }
                ph = Synth.frac(ph + dt)

                if p.gate && gPer > 0 && (t % gPer) >= gOn { continue }

                let o = Float(a * v + off)
                if mono { L[i] += o; continue }
                switch p.ch {
                case .lr: L[i] += o; R[i] += o
                case .l: L[i] += o
                case .r: R[i] += o
                case .lmr: L[i] += o; R[i] -= o
                }
            }
            phase[w] = ph; modPhase[w] = mph
        }
        n += Int64(frames)

        if gain != 1 {
            for i in 0..<frames { L[i] *= gain; R[i] *= gain }
        }
        var pl: Float = 0, pr: Float = 0
        for i in 0..<frames {
            pl = max(pl, abs(L[i])); pr = max(pr, abs(R[i]))
        }
        let m = mono, fl = pl, fr = pr
        lock.withLock { _peakL = fl; _peakR = m ? fl : fr }
    }

    /// 配列版 (表示・レベル計算用)
    func render(frames: Int) -> ([Float], [Float]) {
        var L = [Float](repeating: 0, count: frames), R = L
        L.withUnsafeMutableBufferPointer { lp in
            R.withUnsafeMutableBufferPointer { rp in render(lp.baseAddress!, rp.baseAddress!, frames) }
        }
        return (L, R)
    }

    static func bytesPerSample(_ bits: Int) -> Int { bits == 16 ? 2 : bits == 24 ? 3 : 4 }

    /// WAV 保存 (16/24bit PCM, 32bit float, リトルエンディアン)
    static func writeWav(url: URL, params: [WaveParams], fs: Int, bits: Int, ch: Int, seconds: Double, gain: Float = 1) throws {
        let syn = Synth(fs: fs, params: params, mono: ch == 1, gain: gain)
        let total = Int64(seconds * Double(fs))
        let bps = bytesPerSample(bits), block = bps * ch
        let dataLen = total * Int64(block)
        let isFloat = bits == 32
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "WaveGenFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "ファイルを作成できません: \(url.path)"])
        }
        defer { try? h.close() }
        var hd = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { hd.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { hd.append(contentsOf: $0) } }
        let fmtLen = isFloat ? 18 : 16
        hd.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(truncatingIfNeeded: 4 + 8 + Int64(fmtLen) + 8 + dataLen + (dataLen & 1)))
        hd.append(contentsOf: Array("WAVE".utf8))
        hd.append(contentsOf: Array("fmt ".utf8)); u32(UInt32(fmtLen))
        u16(isFloat ? 3 : 1); u16(UInt16(ch)); u32(UInt32(fs)); u32(UInt32(fs * block))
        u16(UInt16(block)); u16(UInt16(bits))
        if isFloat { u16(0) }
        hd.append(contentsOf: Array("data".utf8)); u32(UInt32(truncatingIfNeeded: dataLen))
        try h.write(contentsOf: hd)

        let chunk = 8192
        let L = UnsafeMutablePointer<Float>.allocate(capacity: chunk), R = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { L.deallocate(); R.deallocate() }
        var buf = [UInt8](repeating: 0, count: chunk * block)
        var done: Int64 = 0
        while done < total {
            let nf = Int(min(Int64(chunk), total - done))
            syn.render(L, R, nf)
            encode(L, R, nf, ch, bits, &buf)
            try h.write(contentsOf: buf[0..<(nf * block)])
            done += Int64(nf)
        }
        if dataLen & 1 != 0 { try h.write(contentsOf: Data([0])) }
    }

    static func encode(_ L: UnsafePointer<Float>, _ R: UnsafePointer<Float>, _ frames: Int, _ ch: Int, _ bits: Int, _ dst: inout [UInt8]) {
        var k = 0
        for i in 0..<frames {
            for c in 0..<ch {
                var v = Double(c == 0 ? L[i] : R[i])
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                if bits == 16 {
                    let x = Int32((v * 32767).rounded(.toNearestOrEven))
                    dst[k] = UInt8(truncatingIfNeeded: x); dst[k + 1] = UInt8(truncatingIfNeeded: x >> 8); k += 2
                } else if bits == 24 {
                    let x = Int32((v * 8388607).rounded(.toNearestOrEven))
                    dst[k] = UInt8(truncatingIfNeeded: x); dst[k + 1] = UInt8(truncatingIfNeeded: x >> 8)
                    dst[k + 2] = UInt8(truncatingIfNeeded: x >> 16); k += 3
                } else {
                    let b = Float(v).bitPattern
                    dst[k] = UInt8(truncatingIfNeeded: b); dst[k + 1] = UInt8(truncatingIfNeeded: b >> 8)
                    dst[k + 2] = UInt8(truncatingIfNeeded: b >> 16); dst[k + 3] = UInt8(truncatingIfNeeded: b >> 24); k += 4
                }
            }
        }
    }
}
