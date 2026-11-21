import CoreAudio
import CoreGraphics
import Foundation
import Testing
@testable import FluxPlatform

@Suite struct LockScreenFeaturesTests {
    @Test func lockAndUnlockSoundsProduceBoundedValidWAVBuffers() throws {
        for (name, data, minBytes) in [
            ("lock", LockScreenSoundEffects.lockSoundData(), 5_000),
            ("unlock", LockScreenSoundEffects.unlockSoundData(), 12_000),
        ] {
            #expect(data.count >= minBytes, "\(name) WAV buffer is unexpectedly short")
            #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
            #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
            #expect(String(data: data.subdata(in: 12..<16), encoding: .ascii) == "fmt ")
            #expect(String(data: data.subdata(in: 36..<40), encoding: .ascii) == "data")

            let pcm = data.subdata(in: 44..<data.count)
            #expect(pcm.count % 2 == 0)
            var peak: Int16 = 0
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for sample in samples {
                    let magnitude = sample == Int16.min ? Int16.max : abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
            }
            // Audible yet restrained — never silent and never anywhere near harsh clipping.
            #expect(peak > 1_500, "\(name) sound is effectively silent")
            #expect(peak < 18_000, "\(name) sound is louder than a reasonable system chime")
        }
    }

    @Test func backdropComposerExtendsAndBlursEdgesOfSquarePhoto() throws {
        // Synthesize a 256x256 square photo with a bright warm center band and high-frequency edge stripes.
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let stripe: UInt8 = ((x / 4) % 2 == 0) ? 230 : 30
                let isEdge = x < 48 || x > side - 48
                pixels[offset] = isEdge ? stripe : 210
                pixels[offset + 1] = isEdge ? stripe : 140
                pixels[offset + 2] = isEdge ? stripe : 95
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let square = try #require(context.makeImage())

        let target = CGSize(width: 1512, height: 982)
        let bundle = try #require(LockScreenBackdropComposer.compose(
            sourceKey: "fixture.square",
            image: square,
            targetAspectSize: target,
            includeDepthEffect: false
        ))

        let expectedSize = LockScreenBackdropComposer.resolvedCanvasSize(for: target)
        #expect(bundle.backdrop.width == Int(expectedSize.width))
        #expect(bundle.backdrop.height == Int(expectedSize.height))
        #expect(bundle.foregroundCutout == nil)

        // Verify left flank is non-transparent and smoothly blurred (low adjacent pixel delta).
        let flankWidth = 32
        var flank = [UInt8](repeating: 0, count: flankWidth * 4)
        let sampleContext = try #require(CGContext(
            data: &flank,
            width: flankWidth,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: flankWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let midY = CGFloat(bundle.backdrop.height / 2)
        if let crop = bundle.backdrop.cropping(to: CGRect(x: 20, y: midY, width: CGFloat(flankWidth), height: 1)) {
            sampleContext.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(flankWidth), height: 1))
        }
        #expect(flank[3] == 255)
        var maxStep = 0
        for x in 1..<flankWidth {
            let delta = abs(Int(flank[x * 4]) - Int(flank[(x - 1) * 4]))
            if delta > maxStep { maxStep = delta }
        }
        // Raw stripes have 200-level jumps; blurred flanks must transition smoothly.
        #expect(maxStep < 30)

        // Verify the center photo remains SHARP near the top and bottom (no vertical mask fade leak).
        var checkerboard = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let v: UInt8 = ((x / 8) % 2 == 0) ? 240 : 20
                checkerboard[offset] = v
                checkerboard[offset + 1] = v
                checkerboard[offset + 2] = v
                checkerboard[offset + 3] = 255
            }
        }
        let sharpCtx = try #require(CGContext(
            data: &checkerboard,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let sharpSquare = try #require(sharpCtx.makeImage())
        let sharpBundle = try #require(LockScreenBackdropComposer.compose(
            sourceKey: "fixture.sharpCenter",
            image: sharpSquare,
            targetAspectSize: target,
            includeDepthEffect: false
        ))
        // Sample a 160px strip across the center near the TOP (y = 12% from top) and BOTTOM (y = 88%).
        let stripW = 160
        var strip = [UInt8](repeating: 0, count: stripW * 4)
        let stripCtx = try #require(CGContext(
            data: &strip,
            width: stripW,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: stripW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for yFrac in [0.12, 0.88] {
            let yPos = CGFloat(sharpBundle.backdrop.height) * yFrac
            let xStart = CGFloat(sharpBundle.backdrop.width - stripW) / 2
            let crop = try #require(sharpBundle.backdrop.cropping(to: CGRect(x: xStart, y: yPos, width: CGFloat(stripW), height: 1)))
            stripCtx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(stripW), height: 1))
            var minLum = 255
            var maxLum = 0
            for x in 0..<stripW {
                let lum = Int(strip[x * 4])
                if lum < minLum { minLum = lum }
                if lum > maxLum { maxLum = lum }
            }
            // Must preserve strong stripe contrast at top & bottom (not washed out by flank blur!).
            #expect(maxLum - minLum > 120)
        }
    }

    @Test func depthClockOverlapSafetyGateRejectsEmptyAndOverwhelmingMasks() {
        #expect(!LockScreenBackdropComposer.acceptsClockOverlap(0.0))
        #expect(!LockScreenBackdropComposer.acceptsClockOverlap(0.01))
        #expect(LockScreenBackdropComposer.acceptsClockOverlap(0.18))
        #expect(LockScreenBackdropComposer.acceptsClockOverlap(0.45))
        #expect(!LockScreenBackdropComposer.acceptsClockOverlap(0.85))
    }

    @Test func audioOutputSymbolMappingCoversCommonDevices() {
        #expect(AudioOutputRoute.symbolName(forName: "AirPods Pro", transportType: kAudioDeviceTransportTypeBluetooth) == "airpodspro")
        #expect(AudioOutputRoute.symbolName(forName: "MacBook Pro Speakers", transportType: kAudioDeviceTransportTypeBuiltIn) == "display")
        #expect(AudioOutputRoute.symbolName(forName: "Living Room", transportType: kAudioDeviceTransportTypeAirPlay) == "airplayaudio")
        #expect(AudioOutputRoute.symbolName(forName: "Studio Headphones", transportType: kAudioDeviceTransportTypeBluetooth) == "headphones")
    }
}
