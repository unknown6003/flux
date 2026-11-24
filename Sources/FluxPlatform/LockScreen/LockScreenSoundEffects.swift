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

    /// Smooth, clean (~165 ms) liquid-glass magnetic settle: velvety downward
    /// thump with a pure glassy harmonic contour and soft cushion detent (zero noise grit).
    public static func lockSoundData() -> Data {
        let duration = 0.165
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var p1 = 0.0
        var p2 = 0.0
        var p3 = 0.0
        var p4 = 0.0

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // 1) Velvety downward low-end thump (235 Hz -> 84 Hz).
            let f1 = 84.0 + 151.0 * exp(-t * 52.0)
            p1 += 2.0 * .pi * f1 / Double(sampleRate)
            let e1 = hannAttack(t, duration: 0.0045) * exp(-t * 32.0)
            let body = sin(p1) * e1 * 0.52

            // 2) Pure liquid-glass harmonic contour (540 Hz -> 252 Hz, zero harsh noise).
            let f2 = 252.0 + 288.0 * exp(-t * 85.0)
            p2 += 2.0 * .pi * f2 / Double(sampleRate)
            let e2 = hannAttack(t, duration: 0.0032) * exp(-t * 82.0)
            let contour = sin(p2) * e2 * 0.24

            // 3) Subtle liquid micro-sparkle (1120 Hz -> 840 Hz).
            let f3 = 840.0 + 280.0 * exp(-t * 140.0)
            p3 += 2.0 * .pi * f3 / Double(sampleRate)
            let e3 = hannAttack(t, duration: 0.0028) * exp(-t * 145.0)
            let sparkle = sin(p3) * e3 * 0.09

            // 4) Soft magnetic cushion settle 30 ms later (138 Hz -> 76 Hz).
            var settle = 0.0
            let t2 = t - 0.030
            if t2 > 0 {
                let f4 = 76.0 + 62.0 * exp(-t2 * 58.0)
                p4 += 2.0 * .pi * f4 / Double(sampleRate)
                let e4 = hannAttack(t2, duration: 0.0065) * exp(-t2 * 34.0)
                settle = sin(p4) * e4 * 0.26
            }

            let tail = hannRelease(t, start: duration - 0.035, duration: 0.035)
            let raw = (body + contour + sparkle + settle) * tail
            let warm = tanh(raw * 1.08) / tanh(1.08)
            samples[i] = Float(warm * 0.78)
        }
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Clean, fresh (~195 ms) elastic release thump opening into a smooth
    /// upward liquid-glass bloom with a silky decay into silence.
    public static func unlockSoundData() -> Data {
        let duration = 0.195
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var p1 = 0.0
        var p2 = 0.0
        var p3 = 0.0
        var p4 = 0.0
        var p5 = 0.0

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // 1) Clean elastic lift thump at t = 0 (130 Hz -> 205 Hz).
            let f1 = 205.0 - 75.0 * exp(-t * 68.0)
            p1 += 2.0 * .pi * f1 / Double(sampleRate)
            let e1 = hannAttack(t, duration: 0.0045) * exp(-t * 48.0)
            let pre = sin(p1) * e1 * 0.36

            // Crisp harmonic contour on initial lift (440 Hz -> 560 Hz).
            let f2 = 560.0 - 120.0 * exp(-t * 110.0)
            p2 += 2.0 * .pi * f2 / Double(sampleRate)
            let e2 = hannAttack(t, duration: 0.0035) * exp(-t * 115.0)
            let preTop = sin(p2) * e2 * 0.14

            // 2) Fresh rising liquid-glass bloom-thump 24 ms later.
            var bloom = 0.0
            var halo = 0.0
            var shimmer = 0.0
            let t2 = t - 0.024
            if t2 > 0 {
                // Elastic warm rising body (165 Hz -> 295 Hz).
                let f3 = 295.0 - 130.0 * exp(-t2 * 56.0)
                p3 += 2.0 * .pi * f3 / Double(sampleRate)
                let e3 = hannAttack(t2, duration: 0.0060) * exp(-t2 * 26.0)
                bloom = sin(p3) * e3 * 0.44

                // Clean liquid-glass fifth/octave overtone (515 Hz -> 590 Hz).
                let f4 = 590.0 - 75.0 * exp(-t2 * 70.0)
                p4 += 2.0 * .pi * f4 / Double(sampleRate)
                let e4 = hannAttack(t2, duration: 0.0085) * exp(-t2 * 42.0)
                halo = sin(p4) * e4 * 0.16

                // Airy fresh upper glass harmonic (1180 Hz).
                p5 += 2.0 * .pi * 1180.0 / Double(sampleRate)
                let e5 = hannAttack(t2, duration: 0.0100) * exp(-t2 * 62.0)
                shimmer = sin(p5) * e5 * 0.065
            }

            let tail = hannRelease(t, start: duration - 0.045, duration: 0.045)
            let raw = (pre + preTop + bloom + halo + shimmer) * tail
            let warm = tanh(raw * 1.08) / tanh(1.08)
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
