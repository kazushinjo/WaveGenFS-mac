import Foundation
import CoreAudio
import AudioToolbox

/// Core Audio (AUHAL) による連続再生。
/// 再生中はデバイスのサンプリング周波数を Fs に合わせ (対応していれば)、停止で元に戻す。
final class AudioOut {
    struct Device { let id: AudioDeviceID; let name: String }

    private(set) var synth: Synth?
    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID = 0
    private var savedRate: Float64 = 0
    private var savedVolumes: [(UInt32, Float32)] = []
    private var bufL: UnsafeMutablePointer<Float>?
    private var bufR: UnsafeMutablePointer<Float>?
    private var bufCap = 0
    /// 実際のデバイス周波数 (Fs と違えば Core Audio がサンプリング周波数変換している)
    private(set) var deviceRate: Double = 0

    var isPlaying: Bool { unit != nil }

    // ------------------------------------------------------------ デバイス一覧
    static func devices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { outputChannels($0) > 0 }.map { Device(id: $0, name: name(of: $0)) }
    }

    static func defaultDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func name(of id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "Device \(id)" }
        return s as String
    }

    static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Float64 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r)
        return r
    }

    private static func availableRates(_ id: AudioDeviceID) -> [AudioValueRange] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
        var r = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r) == noErr else { return [] }
        return r
    }

    @discardableResult
    private static func setNominalRate(_ id: AudioDeviceID, _ rate: Float64) -> Bool {
        if abs(nominalRate(id) - rate) < 0.5 { return true }
        guard availableRates(id).contains(where: { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = rate
        guard AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr else { return false }
        // 切替完了を少し待つ
        for _ in 0..<50 where abs(nominalRate(id) - rate) >= 0.5 { usleep(10_000) }
        return abs(nominalRate(id) - rate) < 0.5
    }

    // ------------------------------------------------------------ 音量 (Volume最大)
    private static func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
        let n = outputChannels(id)
        return ([0] + (0..<UInt32(max(0, n))).map { $0 + 1 }).filter { el in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
        }
    }

    private static func getVolume(_ id: AudioDeviceID, _ el: UInt32) -> Float32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: el)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setVolume(_ id: AudioDeviceID, _ el: UInt32, _ v: Float32) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: el)
        var x = v
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }

    // ------------------------------------------------------------ 再生
    /// - Parameter device: nil = 既定のデバイス
    func start(synth: Synth, device: AudioDeviceID?, latencyMs: Int, fullVolume: Bool) throws {
        stop()
        self.synth = synth
        let dev = device ?? AudioOut.defaultDevice()
        deviceID = dev

        func fail(_ what: String, _ st: OSStatus) -> NSError {
            NSError(domain: "WaveGenFS", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) に失敗しました (OSStatus=\(st))"])
        }

        // デバイスの周波数を Fs に合わせる (非対応ならそのまま。Core Audio が変換する)
        savedRate = AudioOut.nominalRate(dev)
        AudioOut.setNominalRate(dev, Double(synth.fs))
        deviceRate = AudioOut.nominalRate(dev)

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw fail("出力ユニットの取得", -1) }
        var u: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &u)
        guard st == noErr, let au = u else { throw fail("出力ユニットの作成", st) }

        var d = dev
        st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { AudioComponentInstanceDispose(au); throw fail("出力デバイスの選択", st) }

        // 2ch / Float32 / 非インターリーブ (モノラル時は L と同じ信号を両方へ)
        var fmt = AudioStreamBasicDescription(mSampleRate: Double(synth.fs), mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if st != noErr { AudioComponentInstanceDispose(au); throw fail("出力形式 (\(synth.fs)Hz) の設定", st) }

        // 遅延 → デバイスのバッファサイズ (範囲外は丸められる)
        var frames = UInt32(max(64, min(4096, synth.fs * latencyMs / 1000 / 4)))
        AudioObjectSetPropertyData(dev, [AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)],
                                   0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        bufCap = 16384
        bufL = .allocate(capacity: bufCap); bufR = .allocate(capacity: bufCap)

        var cb = AURenderCallbackStruct(inputProc: { ref, _, _, _, nFrames, ioData in
            let me = Unmanaged<AudioOut>.fromOpaque(ref).takeUnretainedValue()
            return me.render(Int(nFrames), ioData)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        st = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if st != noErr { AudioComponentInstanceDispose(au); throw fail("コールバックの設定", st) }

        st = AudioUnitInitialize(au)
        if st != noErr { AudioComponentInstanceDispose(au); throw fail("出力ユニットの初期化", st) }

        // Volume最大: 再生中だけデバイスの音量を最大にし、停止時に戻す
        savedVolumes = []
        if fullVolume {
            for el in AudioOut.volumeElements(dev) {
                if let v = AudioOut.getVolume(dev, el) { savedVolumes.append((el, v)); AudioOut.setVolume(dev, el, 1) }
            }
        }

        st = AudioOutputUnitStart(au)
        if st != noErr {
            AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
            restoreDevice()
            throw fail("再生開始", st)
        }
        unit = au
    }

    private func render(_ frames: Int, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let io = ioData, let syn = synth, let L = bufL, let R = bufR else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(io)
        var done = 0
        while done < frames {
            let nf = min(bufCap, frames - done)
            syn.render(L, R, nf)
            for (c, b) in abl.enumerated() {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let src = (c == 0 || syn.mono) ? L : R
                (p + done).update(from: src, count: nf)
            }
            done += nf
        }
        return noErr
    }

    private func restoreDevice() {
        for (el, v) in savedVolumes { AudioOut.setVolume(deviceID, el, v) }
        savedVolumes = []
        if savedRate > 0 { AudioOut.setNominalRate(deviceID, savedRate) }
        savedRate = 0
    }

    func stop() {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
            restoreDevice()
        }
        bufL?.deallocate(); bufR?.deallocate(); bufL = nil; bufR = nil
        synth = nil
    }

    deinit { stop() }
}
