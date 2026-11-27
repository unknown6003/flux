import CoreAudio
import CoreGraphics
import Foundation
import LocalAuthentication
import Testing
import notify
@testable import FluxPlatform

@Suite struct LockScreenFeaturesTests {
    @Test func lockAndUnlockSoundsProduceBoundedValidWAVBuffers() throws {
        for (name, data, minBytes) in [
            ("lock", LockScreenSoundEffects.lockSoundData(), 6_000),
            ("unlock", LockScreenSoundEffects.unlockSoundData(), 8_000),
        ] {
            #expect(data.count >= minBytes, "\(name) WAV buffer is unexpectedly short")
            #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
            #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
            #expect(String(data: data.subdata(in: 12..<16), encoding: .ascii) == "fmt ")
            #expect(String(data: data.subdata(in: 36..<40), encoding: .ascii) == "data")

            let pcm = data.subdata(in: 44..<data.count)
            #expect(pcm.count % 2 == 0)
            var peak: Int16 = 0
            var firstSample: Int16 = 0
            var secondSample: Int16 = 0
            var tailPeak: Int16 = 0
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                if let first = samples.first { firstSample = first }
                if samples.count > 1 { secondSample = samples[1] }
                let tailStart = max(0, samples.count - 160)
                for (index, sample) in samples.enumerated() {
                    let magnitude = sample == Int16.min ? Int16.max : abs(sample)
                    if magnitude > peak { peak = magnitude }
                    if index >= tailStart, magnitude > tailPeak { tailPeak = magnitude }
                }
            }
            // Crisp tactile click + smooth thump without digital clipping or harsh edge pops.
            #expect(peak > 8_000, "\(name) sound is too quiet to feel tactile")
            #expect(peak < 30_000, "\(name) sound is near digital clipping")
            #expect(abs(Int(firstSample)) < 32, "\(name) sound must start smoothly from silence")
            #expect(abs(Int(secondSample)) < 256, "\(name) sound onset must ramp smoothly without a DC pop")
            #expect(Int(tailPeak) < 64, "\(name) sound tail must melt cleanly into silence")
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

    @Test func backdropComposerSupportsEdgeBlurOffAndCardBackdropCrop() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let w = 400
        let h = 260
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let offset = (y * w + x) * 4
                let stripe: UInt8 = ((x / 4) % 2 == 0) ? 235 : 25
                // Top half red-ish stripes, bottom half blue-ish stripes so Y-flip crop is verifiable.
                pixels[offset] = y < h / 2 ? stripe : 30
                pixels[offset + 1] = 80
                pixels[offset + 2] = y < h / 2 ? 30 : stripe
                pixels[offset + 3] = 255
            }
        }
        let ctx = try #require(CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(ctx.makeImage())
        let target = CGSize(width: 1512, height: 982)
        let sharpFull = try #require(LockScreenBackdropComposer.compose(
            sourceKey: "fixture.noBlur",
            image: image,
            targetAspectSize: target,
            blurEdges: false,
            includeDepthEffect: false
        ))

        // Left flank must stay sharp (high stripe contrast) when blurEdges == false.
        let stripW = 80
        var strip = [UInt8](repeating: 0, count: stripW * 4)
        let stripCtx = try #require(CGContext(
            data: &strip, width: stripW, height: 1,
            bitsPerComponent: 8, bytesPerRow: stripW * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let leftCrop = try #require(sharpFull.backdrop.cropping(to: CGRect(x: 16, y: 120, width: CGFloat(stripW), height: 1)))
        stripCtx.draw(leftCrop, in: CGRect(x: 0, y: 0, width: CGFloat(stripW), height: 1))
        var minR = 255
        var maxR = 0
        for x in 0..<stripW {
            let r = Int(strip[x * 4])
            if r < minR { minR = r }
            if r > maxR { maxR = r }
        }
        #expect(maxR - minR > 100)

        // Card sits in the lower lane (AppKit Y-up: y = 122..270 of 982) -> must crop the blue bottom half.
        let screenFrame = CGRect(origin: .zero, size: target)
        let cardFrame = CGRect(x: 582, y: 122, width: 348, height: 148)
        let slice = try #require(LockScreenBackdropComposer.cropForCard(
            backdrop: sharpFull.backdrop,
            screenFrame: screenFrame,
            cardFrame: cardFrame
        ))
        let expectedRatio = cardFrame.width / cardFrame.height
        let actualRatio = CGFloat(slice.width) / CGFloat(slice.height)
        #expect(abs(expectedRatio - actualRatio) < 0.05)

        // Sample average pixel in the cropped slice: blue channel must exceed red channel.
        var px = [UInt8](repeating: 0, count: 4)
        let pxCtx = try #require(CGContext(
            data: &px, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        pxCtx.draw(slice, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(px[2] > px[0])
    }

    @Test func systemWallpaperMatchesMacOSAspectFillEvenWithEdgeBlurEnabled() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let squareSide = 400
        var squarePixels = [UInt8](repeating: 0, count: squareSide * squareSide * 4)
        for y in 0..<squareSide {
            for x in 0..<squareSide {
                let offset = (y * squareSide + x) * 4
                // Paint top/bottom 17.5% bright red and middle 65% bright green.
                // Under height-fit on a 16:10 canvas the red band stays visible at top;
                // under aspectFill (matching macOS Fill Screen) the top/bottom 17.5% crops out.
                let isTopOrBottomBand = y < 70 || y >= squareSide - 70
                squarePixels[offset] = isTopOrBottomBand ? 240 : 20
                squarePixels[offset + 1] = isTopOrBottomBand ? 20 : 230
                squarePixels[offset + 2] = 30
                squarePixels[offset + 3] = 255
            }
        }
        let squareImage: CGImage = try squarePixels.withUnsafeMutableBytes { rawBuffer in
            let squareCtx = try #require(CGContext(
                data: rawBuffer.baseAddress, width: squareSide, height: squareSide,
                bitsPerComponent: 8, bytesPerRow: squareSide * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try #require(squareCtx.makeImage())
        }
        let target = CGSize(width: 1512, height: 982)
        let systemFill = try #require(LockScreenBackdropComposer.compose(
            sourceKey: "fixture.systemFill",
            image: squareImage,
            targetAspectSize: target,
            blurEdges: true,
            matchSystemFill: true,
            includeDepthEffect: false
        ))
        let topCenterCrop = try #require(systemFill.backdrop.cropping(
            to: CGRect(x: CGFloat(systemFill.backdrop.width / 2), y: 20, width: 1, height: 1)
        ))
        var topPixel = [UInt8](repeating: 0, count: 4)
        try topPixel.withUnsafeMutableBytes { rawBuffer in
            let pixelCtx = try #require(CGContext(
                data: rawBuffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            pixelCtx.draw(topCenterCrop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(topPixel[1] > topPixel[0])
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

    @Test func biometryStateClassificationSeparatesReadyLockoutAndUnavailable() {
        #expect(LockScreenBiometry.classify(canEvaluate: true, errorDomain: nil, errorCode: nil) == .ready)
        #expect(LockScreenBiometry.classify(
            canEvaluate: false,
            errorDomain: LAError.errorDomain,
            errorCode: LAError.Code.biometryLockout.rawValue
        ) == .lockedOut)
        #expect(LockScreenBiometry.classify(
            canEvaluate: false,
            errorDomain: LAError.errorDomain,
            errorCode: LAError.Code.biometryNotAvailable.rawValue
        ) == .unavailable)
        #expect(LockScreenBiometry.classify(
            canEvaluate: false,
            errorDomain: LAError.errorDomain,
            errorCode: LAError.Code.biometryNotEnrolled.rawValue
        ) == .unavailable)
        #expect(LockScreenBiometry.classify(canEvaluate: false, errorDomain: "other", errorCode: -8) == .unavailable)
    }

    @Test @MainActor func biometryLockoutObserverDeliversDarwinNotificationUntilStopped() async throws {
        let name = "org.fluxfixture.biometry.\(UUID().uuidString)"
        var deliveries = 0
        let observer = BiometryLockoutObserver(notificationName: name) {
            deliveries += 1
        }
        defer { observer.stop() }
        #expect(observer.isRegistered)

        notify_post(name)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while deliveries == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(deliveries == 1)

        observer.stop()
        #expect(!observer.isRegistered)
        notify_post(name)
        try await Task.sleep(for: .milliseconds(50))
        #expect(deliveries == 1)
    }
}
