import AppKit
import Foundation

/// Synthesizes refined, low-profile acoustic feedback for locking and unlocking
/// the Mac. Pure 44.1 kHz 16-bit mono PCM WAV buffers mean zero external asset
/// lookups, deterministic playback, and automatic respect for macOS output
/// volume and mute state through `NSSound(data:)`.
public enum LockScreenSoundEffects {
    public static let sampleRate: Int = 44_100

    /// Short (~82 ms), muted tactile glass-latch click settling softly downward.
    public static func lockSoundData() -> Data {
        let duration = 0.082
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var phase1 = 0.0
        var phase2 = 0.0
        var noiseLP = 0.0
        var seed: UInt64 = 0x51A7_9C3B_24F1_8E0D

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // Primary damped woody-glass body sweeping gently down (560 Hz -> 275 Hz).
            let freq1 = 275.0 + 285.0 * exp(-t * 68.0)
            phase1 += 2.0 * .pi * freq1 / Double(sampleRate)
            let attack1 = min(1.0, t / 0.0022)
            let env1 = attack1 * exp(-t * 88.0)
            let body = sin(phase1) * env1 * 0.24

            // Subtle filtered mechanical tap transient (~3.5 ms).
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int64(bitPattern: seed) >> 33) / Double(1 << 30)
            noiseLP = noiseLP * 0.72 + white * 0.28
            let clickEnv = min(1.0, t / 0.0006) * exp(-t * 420.0)
            let click = noiseLP * clickEnv * 0.14

            // Quiet secondary latch settle 20 ms later for tactile closure.
            var latch = 0.0
            let t2 = t - 0.020
            if t2 > 0 {
                let freq2 = 225.0 + 55.0 * exp(-t2 * 95.0)
                phase2 += 2.0 * .pi * freq2 / Double(sampleRate)
                let env2 = min(1.0, t2 / 0.0025) * exp(-t2 * 78.0)
                latch = sin(phase2) * env2 * 0.085
            }

            // Soft end fade to guarantee zero boundary click.
            let tail = t > duration - 0.008 ? max(0.0, (duration - t) / 0.008) : 1.0
            samples[i] = Float((body + click + latch) * tail)
        }
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Airy (~185 ms), translucent rising glass chime (D5 -> A5 pure fifth).
    public static func unlockSoundData() -> Data {
        let duration = 0.185
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)

        let f1 = 587.33 // D5
        let f2 = 880.00 // A5 (warm fifth)

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // First crystalline bloom.
            let a1 = 0.5 - 0.5 * cos(.pi * min(1.0, t / 0.0075))
            let env1 = a1 * exp(-t * 25.0)
            let note1 = (sin(2.0 * .pi * f1 * t)
                + 0.16 * sin(2.0 * .pi * f1 * 2.0 * t)
                + 0.05 * sin(2.0 * .pi * f1 * 3.0 * t)) * env1 * 0.155

            // Second rising bloom 44 ms later.
            var note2 = 0.0
            let t2 = t - 0.044
            if t2 > 0 {
                let a2 = 0.5 - 0.5 * cos(.pi * min(1.0, t2 / 0.0085))
                let env2 = a2 * exp(-t2 * 18.5)
                note2 = (sin(2.0 * .pi * f2 * t2)
                    + 0.12 * sin(2.0 * .pi * f2 * 2.0 * t2)) * env2 * 0.165
            }

            let tail = t > duration - 0.015 ? max(0.0, (duration - t) / 0.015) : 1.0
            samples[i] = Float((note1 + note2) * tail)
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
        sound?.volume = 0.85
        activePlayer = sound
        sound?.play()
    }
}
