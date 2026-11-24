import AppKit
import Foundation

/// Synthesizes refined, low-profile acoustic feedback for locking and unlocking
/// the Mac. Pure 44.1 kHz 16-bit mono PCM WAV buffers mean zero external asset
/// lookups, deterministic playback, and automatic respect for macOS output
/// volume and mute state through `NSSound(data:)`.
public enum LockScreenSoundEffects {
    public static let sampleRate: Int = 44_100

    /// Smooth raised-cosine onset (`0 -> 1`) to guarantee a click-free, velvety attack.
    private static func hannAttack(_ t: Double, duration: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= duration { return 1 }
        return 0.5 - 0.5 * cos(.pi * t / duration)
    }

    /// Smooth raised-cosine release (`1 -> 0`) so the tail melts cleanly into silence.
    private static func hannRelease(_ t: Double, start: Double, duration: Double) -> Double {
        if t <= start { return 1 }
        if t >= start + duration { return 0 }
        return 0.5 + 0.5 * cos(.pi * (t - start) / duration)
    }

    /// Crisp, clean (~132 ms) ceramic-glass click + velvety downward thump
    /// followed by a subtle magnetic detent tick-settle (zero noise grit).
    public static func lockSoundData() -> Data {
        let duration = 0.132
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var pClk1 = 0.0
        var pClk2 = 0.0
        var pTap = 0.0
        var pBody = 0.0
        var pMid = 0.0
        var pSettleClk = 0.0
        var pSettleBody = 0.0

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // 1) Crisp, dry ceramic-glass tactile click at t = 0 (smooth Hann onset, 3-5 ms decay).
            let fClk1 = 1750.0 + 1350.0 * exp(-t * 420.0)
            pClk1 += 2.0 * .pi * fClk1 / Double(sampleRate)
            let clk1 = sin(pClk1) * hannAttack(t, duration: 0.00060) * exp(-t * 360.0) * 0.40

            let fClk2 = 3350.0 + 1300.0 * exp(-t * 540.0)
            pClk2 += 2.0 * .pi * fClk2 / Double(sampleRate)
            let clk2 = sin(pClk2) * hannAttack(t, duration: 0.00050) * exp(-t * 520.0) * 0.22

            // Dry woody-glass tap bridging the click into the thump (1420 Hz -> 940 Hz).
            let fTap = 940.0 + 480.0 * exp(-t * 240.0)
            pTap += 2.0 * .pi * fTap / Double(sampleRate)
            let tap = sin(pTap) * hannAttack(t, duration: 0.00085) * exp(-t * 210.0) * 0.24

            // 2) Velvety downward low-end thump swelling cleanly right behind the click (270 -> 104 Hz).
            let tBody = max(0.0, t - 0.0008)
            let fBody = 104.0 + 166.0 * exp(-tBody * 66.0)
            pBody += 2.0 * .pi * fBody / Double(sampleRate)
            let body = sin(pBody) * hannAttack(tBody, duration: 0.0032) * exp(-tBody * 42.0) * 0.44

            // Clean hollow-glass mid contour (640 Hz -> 340 Hz).
            let fMid = 340.0 + 300.0 * exp(-tBody * 105.0)
            pMid += 2.0 * .pi * fMid / Double(sampleRate)
            let mid = sin(pMid) * hannAttack(tBody, duration: 0.0024) * exp(-tBody * 96.0) * 0.16

            // 3) Subtle magnetic detent micro-click + soft cushion settle 25 ms later.
            var settleClk = 0.0
            var settleBody = 0.0
            let t2 = t - 0.025
            if t2 > 0 {
                let fSClk = 1480.0 + 820.0 * exp(-t2 * 420.0)
                pSettleClk += 2.0 * .pi * fSClk / Double(sampleRate)
                settleClk = sin(pSettleClk) * hannAttack(t2, duration: 0.00065) * exp(-t2 * 380.0) * 0.17

                let fSBody = 92.0 + 74.0 * exp(-t2 * 68.0)
                pSettleBody += 2.0 * .pi * fSBody / Double(sampleRate)
                settleBody = sin(pSettleBody) * hannAttack(t2, duration: 0.0040) * exp(-t2 * 46.0) * 0.22
            }

            let tail = hannRelease(t, start: duration - 0.038, duration: 0.038)
            let raw = (clk1 + clk2 + tap + body + mid + settleClk + settleBody) * tail
            let warm = tanh(raw * 1.05) / tanh(1.05)
            samples[i] = Float(warm * 0.78)
        }
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Clean, fresh (~158 ms) tactile release micro-click followed 24 ms later
    /// by a bright ceramic-glass click blooming into a smooth upward pop-thump.
    public static func unlockSoundData() -> Data {
        let duration = 0.158
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var pC1 = 0.0
        var pC2 = 0.0
        var pPre = 0.0
        var pBC1 = 0.0
        var pBC2 = 0.0
        var pBTap = 0.0
        var pBBody = 0.0
        var pBHalo = 0.0
        var pBAir = 0.0

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // 1) Crisp initial release micro-click + tight elastic pre-lift.
            let fC1 = 3650.0 - 750.0 * exp(-t * 460.0)
            pC1 += 2.0 * .pi * fC1 / Double(sampleRate)
            let c1 = sin(pC1) * hannAttack(t, duration: 0.00055) * exp(-t * 410.0) * 0.28

            pC2 += 2.0 * .pi * 4850.0 / Double(sampleRate)
            let c2 = sin(pC2) * hannAttack(t, duration: 0.00045) * exp(-t * 560.0) * 0.14

            let tPre = max(0.0, t - 0.0006)
            let fPre = 240.0 - 80.0 * exp(-tPre * 78.0)
            pPre += 2.0 * .pi * fPre / Double(sampleRate)
            let pre = sin(pPre) * hannAttack(tPre, duration: 0.0028) * exp(-tPre * 62.0) * 0.26

            // 2) Bright tactile click + fresh rising glass pop 24 ms later.
            var bc1 = 0.0
            var bc2 = 0.0
            var bTap = 0.0
            var bBody = 0.0
            var bHalo = 0.0
            var bAir = 0.0
            let t2 = t - 0.024
            if t2 > 0 {
                let fBC1 = 2650.0 + 1350.0 * exp(-t2 * 400.0)
                pBC1 += 2.0 * .pi * fBC1 / Double(sampleRate)
                bc1 = sin(pBC1) * hannAttack(t2, duration: 0.00055) * exp(-t2 * 350.0) * 0.38

                let fBC2 = 4150.0 + 1350.0 * exp(-t2 * 530.0)
                pBC2 += 2.0 * .pi * fBC2 / Double(sampleRate)
                bc2 = sin(pBC2) * hannAttack(t2, duration: 0.00045) * exp(-t2 * 510.0) * 0.19

                // Crisp glass-marimba tap (1660 Hz -> 2020 Hz).
                let fBTap = 2020.0 - 360.0 * exp(-t2 * 240.0)
                pBTap += 2.0 * .pi * fBTap / Double(sampleRate)
                bTap = sin(pBTap) * hannAttack(t2, duration: 0.00085) * exp(-t2 * 185.0) * 0.20

                // Smooth rising elastic pop-thump right behind the click (205 Hz -> 375 Hz).
                let t2b = max(0.0, t2 - 0.0008)
                let fBBody = 375.0 - 170.0 * exp(-t2b * 68.0)
                pBBody += 2.0 * .pi * fBBody / Double(sampleRate)
                bBody = sin(pBBody) * hannAttack(t2b, duration: 0.0032) * exp(-t2b * 34.0) * 0.39

                // Fresh liquid-glass overtone (760 Hz -> 890 Hz).
                let fBHalo = 890.0 - 130.0 * exp(-t2b * 82.0)
                pBHalo += 2.0 * .pi * fBHalo / Double(sampleRate)
                bHalo = sin(pBHalo) * hannAttack(t2b, duration: 0.0045) * exp(-t2b * 48.0) * 0.15

                // Airy upper harmonic sheen (1520 Hz -> 1780 Hz).
                let fBAir = 1780.0 - 260.0 * exp(-t2b * 92.0)
                pBAir += 2.0 * .pi * fBAir / Double(sampleRate)
                bAir = sin(pBAir) * hannAttack(t2b, duration: 0.0065) * exp(-t2b * 68.0) * 0.065
            }

            let tail = hannRelease(t, start: duration - 0.044, duration: 0.044)
            let raw = (c1 + c2 + pre + bc1 + bc2 + bTap + bBody + bHalo + bAir) * tail
            let warm = tanh(raw * 1.05) / tanh(1.05)
            samples[i] = Float(warm * 0.78)
        }
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Encodes normalized floating-point samples in `-1...1` as 16-bit mono PCM WAV.
    static func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let riffSize = UInt32(36) + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        append(riffSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample.isFinite ? sample : 0))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            append(scaled)
        }
        return data
    }
}

/// Retains and plays synthesized lock/unlock sounds on the main actor.
@MainActor
public enum LockScreenSoundPlayer {
    private static let lockData = LockScreenSoundEffects.lockSoundData()
    private static let unlockData = LockScreenSoundEffects.unlockSoundData()
    private static var activePlayer: NSSound?

    public static func playLock() {
        play(data: lockData, fallbackNames: ["Tink", "Pop"])
    }

    public static func playUnlock() {
        play(data: unlockData, fallbackNames: ["Glass", "Pop", "Tink"])
    }

    private static func play(data: Data, fallbackNames: [String]) {
        activePlayer?.stop()
        let sound = NSSound(data: data) ?? fallbackNames.lazy.compactMap { NSSound(named: $0) }.first
        sound?.volume = 0.95
        activePlayer = sound
        sound?.play()
    }
}
