import AppKit
import Foundation

/// Synthesizes refined, low-profile acoustic feedback for locking and unlocking
/// the Mac. Pure 44.1 kHz 16-bit mono PCM WAV buffers mean zero external asset
/// lookups, deterministic playback, and automatic respect for macOS output
/// volume and mute state through `NSSound(data:)`.
public enum LockScreenSoundEffects {
    public static let sampleRate: Int = 44_100

    /// Smooth raised-cosine bell centered at `center` with total width `width`.
    private static func hannBell(_ t: Double, center: Double, width: Double) -> Double {
        let u = (t - (center - width * 0.5)) / width
        if u <= 0 || u >= 1 { return 0 }
        return 0.5 - 0.5 * cos(2.0 * .pi * u)
    }

    /// Smooth raised-cosine onset (`0 -> 1`) to guarantee a click-free attack.
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

    /// Single-stage 2-pole bandpass resonator (constant 0 dB peak, open high-end air).
    private struct BiquadBandpass {
        let b0: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var z1: Double = 0
        var z2: Double = 0

        init(frequency: Double, q: Double, sampleRate: Double) {
            let w0 = 2.0 * .pi * frequency / sampleRate
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = (-2.0 * cos(w0)) / a0
            a2 = (1.0 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = -a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// 2-pole Butterworth high-pass filter to strip low-end mud cleanly.
    private struct BiquadHighpass {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var z1: Double = 0
        var z2: Double = 0

        init(frequency: Double, q: Double = 0.707, sampleRate: Double) {
            let w0 = 2.0 * .pi * frequency / sampleRate
            let cw = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha
            b0 = ((1.0 + cw) * 0.5) / a0
            b1 = (-(1.0 + cw)) / a0
            b2 = ((1.0 + cw) * 0.5) / a0
            a1 = (-2.0 * cw) / a0
            a2 = (1.0 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// Deterministic xorshift64* PRNG yielding repeatable bipolar excitation in `-1...1`.
    private struct DeterministicNoise {
        var state: UInt64

        mutating func nextBipolar() -> Double {
            var x = state
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            state = x
            let value = x &* 2_685_821_657_736_338_717
            return (Double(value >> 11) / Double(1 << 53)) * 2.0 - 1.0
        }
    }

    /// Synthesizes a peak-normalized physical click burst by exciting single-stage
    /// 2-pole modal resonators with a short Hann-windowed impulse and high-passing out mud.
    private static func makeCrispClick(
        count: Int,
        onset: Double,
        burstMs: Double,
        seed: UInt64,
        modes: [(frequency: Double, q: Double, weight: Double)],
        level: Double,
        highPassHz: Double
    ) -> [Double] {
        let sr = Double(sampleRate)
        var rng = DeterministicNoise(state: seed)
        var filters = modes.map { BiquadBandpass(frequency: $0.frequency, q: $0.q, sampleRate: sr) }
        var hp = highPassHz > 0 ? BiquadHighpass(frequency: highPassHz, sampleRate: sr) : nil
        var buffer = [Double](repeating: 0, count: count)
        let burstSeconds = burstMs / 1000.0
        let center = onset + burstSeconds * 0.5

        for i in 0..<count {
            let t = Double(i) / sr
            let env = hannBell(t, center: center, width: burstSeconds)
            let exc = env > 0 ? (rng.nextBipolar() * 0.76 + 0.24) * env : 0
            var y = 0.0
            for index in filters.indices {
                y += filters[index].process(exc) * modes[index].weight
            }
            if hp != nil {
                y = hp!.process(y)
            }
            buffer[i] = y
        }

        let peak = buffer.reduce(0.0) { max($0, abs($1)) }
        let scale = peak > 0 ? level / peak : 0
        if scale != 1 {
            for i in buffer.indices { buffer[i] *= scale }
        }
        return buffer
    }

    private static func normalizeAndFinish(
        _ input: [Double],
        targetPeak: Double,
        fadeInMs: Double,
        fadeOutMs: Double
    ) -> [Float] {
        let count = input.count
        guard count > 0 else { return [] }
        let sr = Double(sampleRate)
        let mean = input.reduce(0.0, +) / Double(count)
        let duration = Double(count) / sr
        let fadeIn = fadeInMs / 1000.0
        let fadeOut = fadeOutMs / 1000.0

        var shaped = [Double](repeating: 0, count: count)
        var peak = 0.0
        for i in 0..<count {
            let t = Double(i) / sr
            let v = (input[i] - mean) * hannAttack(t, duration: fadeIn) * hannRelease(t, start: duration - fadeOut, duration: fadeOut)
            shaped[i] = v
            peak = max(peak, abs(v))
        }
        let scale = peak > 0 ? targetPeak / peak : 0
        let satDrive = 1.04
        let satGain = targetPeak / (tanh(targetPeak * satDrive) / tanh(satDrive))
        return shaped.map { sample in
            let v = sample * scale
            return Float((tanh(v * satDrive) / tanh(satDrive)) * satGain)
        }
    }

    /// Fresh, open (~168 ms) two-stage glass-ceramic latch lock: crisp dry
    /// high-end click followed 50 ms later by a tight warm settle with subtle
    /// fifth/octave glass clarity and a clean fade to silence.
    public static func lockSoundData() -> Data {
        let duration = 0.168
        let count = Int(Double(sampleRate) * duration)
        let sr = Double(sampleRate)

        let hit1 = makeCrispClick(
            count: count,
            onset: 0.0015,
            burstMs: 1.05,
            seed: 0xC201_0001,
            modes: [
                (3750.0, 4.4, 0.78),
                (6300.0, 4.8, 0.95),
                (9600.0, 4.0, 0.85),
                (13_000.0, 3.4, 0.55),
            ],
            level: 1.00,
            highPassHz: 1600.0
        )
        let seatClk = makeCrispClick(
            count: count,
            onset: 0.050,
            burstMs: 1.10,
            seed: 0xC201_0002,
            modes: [
                (3350.0, 4.6, 0.70),
                (5950.0, 5.0, 0.82),
                (9500.0, 4.2, 0.68),
            ],
            level: 0.62,
            highPassHz: 1400.0
        )
        let chamber = makeCrispClick(
            count: count,
            onset: 0.0495,
            burstMs: 2.2,
            seed: 0xC201_0003,
            modes: [
                (330.0, 4.0, 0.80),
                (660.0, 5.2, 0.65),
                (990.0, 5.8, 0.45),
                (1980.0, 6.2, 0.34),
            ],
            level: 0.44,
            highPassHz: 180.0
        )

        var mixed = [Double](repeating: 0, count: count)
        var pLow = 0.0
        var pG1 = 0.0
        var pG2 = 0.0

        for i in 0..<count {
            let t = Double(i) / sr
            var low = 0.0
            var glassSettle = 0.0
            let t2 = t - 0.050
            if t2 > 0 {
                let fLow = 164.0 + 146.0 * exp(-t2 * 105.0)
                pLow += 2.0 * .pi * fLow / sr
                low = sin(pLow) * hannAttack(t2, duration: 0.0024) * exp(-t2 * 72.0) * 0.24

                let fG1 = 880.0 + 108.0 * exp(-t2 * 140.0)
                pG1 += 2.0 * .pi * fG1 / sr
                let fG2 = 1760.0 + 216.0 * exp(-t2 * 160.0)
                pG2 += 2.0 * .pi * fG2 / sr
                glassSettle =
                    sin(pG1) * hannAttack(t2, duration: 0.0018) * exp(-t2 * 95.0) * 0.11 +
                    sin(pG2) * hannAttack(t2, duration: 0.0014) * exp(-t2 * 135.0) * 0.06
            }
            mixed[i] = hit1[i] + seatClk[i] + chamber[i] + low + glassSettle
        }

        let samples = normalizeAndFinish(mixed, targetPeak: 0.72, fadeInMs: 0.7, fadeOutMs: 34.0)
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Crisp, airy (~145 ms) precision release unlock: feather-light opening
    /// tick into an open ceramic-titanium release snap at 26 ms and a delicate
    /// rising upper air tick at 54 ms, with zero low-end mud.
    public static func unlockSoundData() -> Data {
        let duration = 0.145
        let count = Int(Double(sampleRate) * duration)

        let pre = makeCrispClick(
            count: count,
            onset: 0.0015,
            burstMs: 0.95,
            seed: 0xC102_0001,
            modes: [
                (4650.0, 4.2, 0.72),
                (7900.0, 4.0, 0.90),
                (11_800.0, 3.5, 0.68),
            ],
            level: 0.44,
            highPassHz: 1800.0
        )
        let main = makeCrispClick(
            count: count,
            onset: 0.026,
            burstMs: 1.15,
            seed: 0xC102_0002,
            modes: [
                (3850.0, 4.2, 0.75),
                (6450.0, 4.6, 1.00),
                (9900.0, 4.0, 0.88),
                (13_200.0, 3.4, 0.55),
            ],
            level: 1.00,
            highPassHz: 1400.0
        )
        let glass = makeCrispClick(
            count: count,
            onset: 0.026,
            burstMs: 2.0,
            seed: 0xC102_0003,
            modes: [
                (620.0, 5.2, 0.55),
                (1240.0, 5.8, 0.62),
                (2480.0, 6.2, 0.45),
            ],
            level: 0.34,
            highPassHz: 380.0
        )
        let airTick = makeCrispClick(
            count: count,
            onset: 0.054,
            burstMs: 0.90,
            seed: 0xC102_0004,
            modes: [
                (6200.0, 5.5, 0.75),
                (9400.0, 5.0, 0.80),
                (12_800.0, 4.2, 0.48),
            ],
            level: 0.28,
            highPassHz: 2400.0
        )

        var mixed = [Double](repeating: 0, count: count)
        for i in 0..<count {
            mixed[i] = pre[i] + main[i] + glass[i] + airTick[i]
        }

        let samples = normalizeAndFinish(mixed, targetPeak: 0.70, fadeInMs: 0.7, fadeOutMs: 36.0)
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
