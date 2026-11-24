import AppKit
import Foundation

/// Synthesizes refined, low-profile acoustic feedback for locking and unlocking
/// the Mac. Pure 44.1 kHz 16-bit mono PCM WAV buffers mean zero external asset
/// lookups, deterministic playback, and automatic respect for macOS output
/// volume and mute state through `NSSound(data:)`.
public enum LockScreenSoundEffects {
    public static let sampleRate: Int = 44_100

    /// Strong, clean (~95 ms) precision magnetic-latch click with a weighted low thump.
    public static func lockSoundData() -> Data {
        let duration = 0.095
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var phaseSub = 0.0
        var phaseKnock = 0.0
        var phaseSettle = 0.0
        var lp1 = 0.0
        var lp2 = 0.0
        var seed: UInt64 = 0x51A7_9C3B_24F1_8E0D

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // Weighted low-end thump dropping smoothly (170 Hz -> 56 Hz).
            let freqSub = 56.0 + 114.0 * exp(-t * 72.0)
            phaseSub += 2.0 * .pi * freqSub / Double(sampleRate)
            let attackSub = min(1.0, t / 0.0014)
            let envSub = attackSub * exp(-t * 42.0)
            let sub = sin(phaseSub) * envSub * 0.54

            // Tight woody-aluminum knock resonance (1320 Hz -> 540 Hz, ~7 ms).
            let freqKnock = 540.0 + 780.0 * exp(-t * 280.0)
            phaseKnock += 2.0 * .pi * freqKnock / Double(sampleRate)
            let envKnock = min(1.0, t / 0.0004) * exp(-t * 260.0)
            let knock = sin(phaseKnock) * envKnock * 0.28

            // Band-limited crisp mechanical transient (~2.5 ms).
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int64(bitPattern: seed) >> 33) / Double(1 << 30)
            lp1 = lp1 * 0.60 + white * 0.40
            lp2 = lp2 * 0.88 + lp1 * 0.12
            let bandClick = lp1 - lp2
            let clickEnv = min(1.0, t / 0.0003) * exp(-t * 620.0)
            let click = bandClick * clickEnv * 0.46

            // Subtle secondary latch detent 20 ms later for solid closed feel.
            var settle = 0.0
            let t2 = t - 0.020
            if t2 > 0 {
                let freq2 = 72.0 + 68.0 * exp(-t2 * 110.0)
                phaseSettle += 2.0 * .pi * freq2 / Double(sampleRate)
                let env2 = min(1.0, t2 / 0.0016) * exp(-t2 * 64.0)
                settle = sin(phaseSettle) * env2 * 0.18
            }

            let tail = t > duration - 0.010 ? max(0.0, (duration - t) / 0.010) : 1.0
            let raw = (sub + knock + click + settle) * tail
            let warm = tanh(raw * 1.15) / tanh(1.15)
            samples[i] = Float(warm * 0.78)
        }
        return encodeWAV(samples: samples, sampleRate: sampleRate)
    }

    /// Clean, tactile (~110 ms) mechanical release click followed by a warm upward pop-thump.
    public static func unlockSoundData() -> Data {
        let duration = 0.110
        let count = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: count)
        var phaseTick = 0.0
        var phaseThump = 0.0
        var phaseAir = 0.0
        var lp1 = 0.0
        var lp2 = 0.0
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            // Crisp initial unlatch tick at t = 0.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int64(bitPattern: seed) >> 33) / Double(1 << 30)
            lp1 = lp1 * 0.52 + white * 0.48
            lp2 = lp2 * 0.85 + lp1 * 0.15
            let tickNoise = (lp1 - lp2) * min(1.0, t / 0.0003) * exp(-t * 720.0) * 0.36

            let freqTick = 880.0 + 420.0 * exp(-t * 260.0)
            phaseTick += 2.0 * .pi * freqTick / Double(sampleRate)
            let tickTone = sin(phaseTick) * min(1.0, t / 0.0005) * exp(-t * 240.0) * 0.22

            // Confident warm release thump 15 ms later rising cleanly (98 Hz -> 185 Hz).
            var thump = 0.0
            var air = 0.0
            let t2 = t - 0.015
            if t2 > 0 {
                let freqThump = 185.0 - 87.0 * exp(-t2 * 95.0)
                phaseThump += 2.0 * .pi * freqThump / Double(sampleRate)
                let attack2 = min(1.0, t2 / 0.0018)
                let env2 = attack2 * exp(-t2 * 38.0)
                thump = (sin(phaseThump) + 0.22 * sin(phaseThump * 2.0)) * env2 * 0.48

                // Subtle damped high-end release sheen (zero bell ring).
                phaseAir += 2.0 * .pi * 1180.0 / Double(sampleRate)
                let envAir = min(1.0, t2 / 0.0010) * exp(-t2 * 145.0)
                air = sin(phaseAir) * envAir * 0.10
            }

            let tail = t > duration - 0.012 ? max(0.0, (duration - t) / 0.012) : 1.0
            let raw = (tickNoise + tickTone + thump + air) * tail
            let warm = tanh(raw * 1.15) / tanh(1.15)
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
