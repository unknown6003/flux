import AppKit
import Testing
@testable import FluxPlatform

@MainActor struct StatusMenuWindowPreviewTests {
    private let display = StatusPreviewDisplay(id: 7,
        frame: CGRect(x: -200, y: -40, width: 400, height: 300), pixelScale: 2)
    private let menuFrame = CGRect(x: -200, y: -40, width: 400, height: 33)

    private func window(_ id: CGWindowID = 1, owner: String = "com.apple.MenuBarAgent",
                        frame: CGRect? = nil, displayID: CGDirectDisplayID = 7) -> StatusPreviewMenuWindow {
        .init(id: id, application: owner, displayID: displayID, frame: frame ?? menuFrame)
    }

    private func plan(x: CGFloat = -150) throws -> StatusPreviewPlan {
        let region = StatusPreviewRegion(id: UUID(), displayID: 7,
            frame: CGRect(x: x, y: -35.5, width: 24, height: 24))
        return try #require(StatusPreviewPlan.make([region], displays: [display]).first)
    }

    private func image(glyph: Bool = true, width: Int = 800, height: Int = 66) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if glyph {
            context.setFillColor(CGColor(red: 0.1, green: 0.95, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 110, y: 18, width: 20, height: 30))
        }
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    private func transparentVariant() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 800, height: 66, bitsPerComponent: 8,
            bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 0.75))
        context.fill(CGRect(x: 105, y: 15, width: 30, height: 36))
        return try #require(context.makeImage())
    }

    @Test func menuWindowRegressionScenarios() async throws {
        var failures: [String] = []
        func check(_ name: String, _ passed: Bool) {
            print("MENU_WINDOW_SCENARIO \(name) \(passed ? "PASS" : "FAIL")")
            if !passed { failures.append(name) }
        }
        let request = try plan()
        let full = try image()
        let expected = try #require(full.cropping(to: CGRect(x: 100, y: 9, width: 48, height: 48)))
        let expectedPixels = try pixels(expected)
        var calls = 0
        let source = StatusMenuWindowPreview(windows: [window()], displays: [display]) { _ in
            calls += 1
            return full
        }
        let first = try await source.capture(request)
        check("exact-secondary-display-crop", try first.map { try pixels($0) == expectedPixels } ?? false)
        _ = try await source.capture(try plan(x: -100))
        check("one-window-photo-per-batch", calls == 1)

        let variants = StatusMenuWindowPreview(windows: [window(1), window(2), window(3)], displays: [display]) { item in
            if item.id == 2 { return try transparentVariant() }
            return try image(glyph: item.id == 3)
        }
        let visible = try await variants.capture(request)
        check("blank-variant-never-wins", try visible.map { try pixels($0) == expectedPixels } ?? false)

        for (name, windows) in [
            ("foreign-owner", [window(owner: "org.other.app")]),
            ("desktop-window", [window(frame: display.frame)]),
            ("wrong-display", [window(displayID: 8)]),
            ("outside-menu-band", [window(frame: CGRect(x: -200, y: 0, width: 400, height: 33))]),
            ("duplicate-window", [window(), window()]),
            ("candidate-budget", (1...5).map { window(CGWindowID($0)) }),
        ] {
            var rejectedCalls = 0
            let rejected = StatusMenuWindowPreview(windows: windows, displays: [display]) { _ in
                rejectedCalls += 1
                return full
            }
            let result = try await rejected.capture(request)
            check(name, result == nil && rejectedCalls == 0)
        }

        let wrongSize = StatusMenuWindowPreview(windows: [window()], displays: [display]) { _ in
            try image(width: 1, height: 1)
        }
        check("reject-provider-size", try await wrongSize.capture(request) == nil)

        var cancelledCalls = 0
        let cancelled = StatusMenuWindowPreview(windows: [window()], displays: [display]) { _ in
            cancelledCalls += 1
            return full
        }
        let task = Task { try await cancelled.capture(request) }
        task.cancel()
        var cancelledCorrectly = false
        do { _ = try await task.value } catch is CancellationError { cancelledCorrectly = true }
        check("cancel-before-capture", cancelledCorrectly && cancelledCalls == 0)

        var current = true
        var closeCalls = 0
        let closing = StatusMenuWindowPreview(windows: [window(1), window(2)], displays: [display]) { _ in
            closeCalls += 1
            current = false
            return full
        }
        var closedCorrectly = false
        do {
            _ = try await closing.capture(request, checking: {
                if !current { throw StatusPreviewError.cancelled }
            })
        } catch StatusPreviewError.cancelled { closedCorrectly = true }
        check("close-stops-remaining-variants", closedCorrectly && closeCalls == 1)

        let width = 800, height = 66, count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        bytes.initialize(repeating: 0, count: count)
        defer { bytes.deinitialize(count: count); bytes.deallocate() }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value: UInt8 = x >= 110 && x < 130 && y >= 18 && y < 48 ? 240 : 0
                for channel in 0..<3 { bytes[offset + channel] = value }
                bytes[offset + 3] = 255
            }
        }
        let backing = CGDataProvider(dataInfo: nil, data: bytes, size: count, releaseData: { _, _, _ in })
        let provider = try #require(backing)
        let mutable = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let owned = StatusMenuWindowPreview(windows: [window()], displays: [display]) { _ in mutable }
        let before = try await owned.capture(request)
        let saved = try before.map { try pixels($0) }
        for index in 0..<(width * height) { for channel in 0..<3 { bytes[index * 4 + channel] = 0 } }
        let after = try await owned.capture(request)
        check("cached-window-owns-pixels", try saved != nil && after.map { try pixels($0) } == saved)

        print("MENU_WINDOW_FAILURES=\(failures.count)")
        #expect(failures.isEmpty)
    }
}
