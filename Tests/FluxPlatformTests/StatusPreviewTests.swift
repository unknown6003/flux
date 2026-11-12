import AppKit
import Testing
@testable import FluxPlatform

@MainActor struct StatusPreviewTests {
    @Test func changedOwnershipDuringScreenshotDiscardsTheWholeBatch() async throws {
        var captures = 0
        var validations = 0
        let preview = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                captures += 1
                return try image(plan)
            })
        })
        preview.open()
        await #expect(throws: StatusPreviewError.invalidRegion) {
            try await preview.capture([region(), region()], validating: { _ in
                validations += 1
                // The owner changes while the first screenshot is in flight.
                return validations == 1
            })
        }
        #expect(captures == 1)
        #expect(validations == 2)
    }

    private let display = StatusPreviewDisplay(id: 7,
        frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080), pixelScale: 2)

    private func region(_ frame: CGRect = CGRect(x: -100, y: -100, width: 24, height: 24),
                        displayID: CGDirectDisplayID = 7) -> StatusPreviewRegion {
        .init(id: UUID(), displayID: displayID, frame: frame)
    }

    private func image(_ plan: StatusPreviewPlan) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: plan.pixelWidth, height: plan.pixelHeight,
            bitsPerComponent: 8, bytesPerRow: plan.pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A real item: a dark menu bar with a light glyph. Flat photos are dropped.
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: plan.pixelWidth / 4, y: plan.pixelHeight / 4,
                            width: plan.pixelWidth / 2, height: plan.pixelHeight / 2))
        return try #require(context.makeImage())
    }

    @Test func aFlatPhotoIsDroppedSoTheTileFallsBackToTheAppIcon() async throws {
        let preview = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                let context = try #require(CGContext(data: nil, width: plan.pixelWidth, height: plan.pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: plan.pixelWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
                return try #require(context.makeImage())
            })
        })
        preview.open()
        #expect(try await preview.capture([region()], validating: { _ in true }).isEmpty)
    }

    @Test func deliveredPreviewOwnsItsPixelsAfterCaptureReturns() async throws {
        let width = 48, height = 48, count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        bytes.initialize(repeating: 0, count: count)
        defer { bytes.deinitialize(count: count); bytes.deallocate() }
        for index in 0..<(width * height) {
            let value: UInt8 = (index % width > 12 && index % width < 36) ? 240 : 20
            for channel in 0..<3 { bytes[index * 4 + channel] = value }
            bytes[index * 4 + 3] = 255
        }
        let provider = try #require(CGDataProvider(dataInfo: nil, data: bytes, size: count,
            releaseData: { _, _, _ in }))
        let sourceImage = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let preview = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { _ in sourceImage })
        })
        preview.open()
        let result = try #require(try await preview.capture([region()], validating: { _ in true }).first)
        // Simulate capture-owned storage being cleared after delivery.
        for index in 0..<(width * height) {
            for channel in 0..<3 { bytes[index * 4 + channel] = 0 }
        }
        let delivered = try #require(result.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(!StatusPreviewContent.isBlank(delivered))
    }

    @Test func mapsSecondaryDisplayWithoutExpandingFractionalCrop() throws {
        let request = region(CGRect(x: -100.25, y: -99.5, width: 24.25, height: 23.5))
        let plan = try #require(StatusPreviewPlan.make([request], displays: [display]).first)
        #expect(plan.sourceRect == CGRect(x: 1819.75, y: 0.5, width: 24.25, height: 23.5))
        #expect(plan.pixelWidth == 49)
        #expect(plan.pixelHeight == 47)
    }

    @Test func rejectsMalformedOffscreenAndUnassociatedRegions() {
        let frames = [
            CGRect(x: CGFloat.nan, y: -100, width: 24, height: 24),
            CGRect(x: -100, y: -100, width: CGFloat.infinity, height: 24),
            CGRect(x: -100, y: -100, width: -24, height: 24),
            CGRect(x: -100, y: -100, width: 0, height: 24),
            CGRect(x: -100, y: -101, width: 24, height: 24),
            CGRect(x: -10, y: -100, width: 24, height: 24),
            CGRect(x: -100, y: -50, width: 24, height: 24),
            CGRect(x: -1000, y: -100, width: 257, height: 24),
            CGRect(x: -100, y: -100, width: 24, height: 65),
            CGRect(x: 200_000, y: -100, width: 24, height: 24)
        ]
        for frame in frames {
            #expect(throws: StatusPreviewError.invalidRegion) {
                try StatusPreviewPlan.make([region(frame)], displays: [display])
            }
        }
        #expect(throws: StatusPreviewError.invalidRegion) {
            try StatusPreviewPlan.make([region(displayID: 8)], displays: [display])
        }
        #expect(throws: StatusPreviewError.invalidRegion) {
            try StatusPreviewPlan.make([region()], displays: [display, display])
        }
        let wholeDisplay = CGRect(x: -100, y: -100, width: 24, height: 24)
        #expect(throws: StatusPreviewError.invalidRegion) {
            try StatusPreviewPlan.make([region(wholeDisplay)], displays: [
                .init(id: 7, frame: wholeDisplay, pixelScale: 2)
            ])
        }
        for scale in [CGFloat.nan, .infinity, 0, 4.1] {
            #expect(throws: StatusPreviewError.invalidRegion) {
                try StatusPreviewPlan.make([region()], displays: [
                    .init(id: 7, frame: display.frame, pixelScale: scale)
                ])
            }
        }
    }

    @Test func rejectsCountDuplicateIDsAndPixelBudgetBeforeCapture() throws {
        #expect(throws: StatusPreviewError.budgetExceeded) {
            try StatusPreviewPlan.make((0..<129).map { _ in region() }, displays: [display])
        }
        let repeated = region()
        #expect(throws: StatusPreviewError.invalidRegion) {
            try StatusPreviewPlan.make([repeated, repeated], displays: [display])
        }
        let largeDisplay = StatusPreviewDisplay(id: 7, frame: display.frame, pixelScale: 4)
        let largeRegions = (0..<17).map { _ in
            region(CGRect(x: -1000, y: -100, width: 256, height: 64))
        }
        #expect(throws: StatusPreviewError.budgetExceeded) {
            try StatusPreviewPlan.make(largeRegions, displays: [largeDisplay])
        }
        #expect(try StatusPreviewPlan.make(Array(largeRegions.prefix(16)),
                                          displays: [largeDisplay]).count == 16)
    }

    @Test func noPermissionAndInvalidCountNeverReadCaptureContent() async throws {
        var sourceReads = 0
        let preview = StatusPreview(permission: { false }, source: {
            sourceReads += 1
            throw StatusPreviewError.unavailable
        })
        await #expect(throws: StatusPreviewError.closed) { try await preview.capture([region()], validating: { _ in true }) }
        preview.open()
        await #expect(throws: StatusPreviewError.permissionRequired) { try await preview.capture([region()], validating: { _ in true }) }
        #expect(sourceReads == 0)

        let allowed = StatusPreview(permission: { true }, source: {
            sourceReads += 1
            throw StatusPreviewError.unavailable
        })
        allowed.open()
        await #expect(throws: StatusPreviewError.budgetExceeded) {
            try await allowed.capture((0..<129).map { _ in region() }, validating: { _ in true })
        }
        #expect(try await allowed.capture([], validating: { _ in true }).isEmpty)
        #expect(sourceReads == 0)
    }

    @Test func serialCaptureReturnsOnlyRequestedImagesAndRejectsReentry() async throws {
        var owner: StatusPreview?
        defer { owner = nil }
        var calls = 0
        let requests = [region(), region(CGRect(x: -200, y: -100, width: 32, height: 24))]
        owner = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                calls += 1
                let preview = try #require(owner)
                await #expect(throws: StatusPreviewError.busy) { try await preview.capture([region()], validating: { _ in true }) }
                return try image(plan)
            })
        })
        let preview = try #require(owner)
        preview.open()
        let images = try await preview.capture(requests, validating: { _ in true })
        #expect(images.map(\.id) == requests.map(\.id))
        #expect(images.map { $0.image.size } == requests.map { $0.frame.size })
        #expect(calls == 2)
    }

    @Test func closeAndReopenDiscardOldBatchBeforeSecondScreenshot() async throws {
        var owner: StatusPreview?
        defer { owner = nil }
        var calls = 0
        owner = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                calls += 1
                owner?.close()
                owner?.open()
                return try image(plan)
            })
        })
        let preview = try #require(owner)
        preview.open()
        await #expect(throws: StatusPreviewError.cancelled) {
            try await preview.capture([region(), region()], validating: { _ in true })
        }
        #expect(calls == 1)
    }

    @Test func permissionRevocationDiscardsReturnedImage() async throws {
        var allowed = true
        var calls = 0
        let preview = StatusPreview(permission: { allowed }, source: {
            .init(displays: [display], capture: { plan in
                calls += 1
                allowed = false
                return try image(plan)
            })
        })
        preview.open()
        await #expect(throws: StatusPreviewError.permissionRequired) {
            try await preview.capture([region(), region()], validating: { _ in true })
        }
        #expect(calls == 1)
    }

    @Test func validatesWholeBatchBeforeAnyScreenshot() async throws {
        var calls = 0
        let preview = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                calls += 1
                return try image(plan)
            })
        })
        preview.open()
        await #expect(throws: StatusPreviewError.invalidRegion) {
            try await preview.capture([region(), region(displayID: 8)], validating: { _ in true })
        }
        #expect(calls == 0)
    }

    @Test func cancellationAfterScreenshotDiscardsImageAndStopsBatch() async throws {
        var calls = 0
        let preview = StatusPreview(permission: { true }, source: {
            .init(displays: [display], capture: { plan in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return try image(plan)
            })
        })
        preview.open()
        let task = Task { @MainActor in
            await #expect(throws: StatusPreviewError.cancelled) {
                try await preview.capture([region(), region()], validating: { _ in true })
            }
        }
        await task.value
        #expect(calls == 1)
    }

    @Test func cancellationAndSystemErrorsUseFixedErrors() async throws {
        var sourceReads = 0
        let preview = StatusPreview(permission: { true }, source: {
            sourceReads += 1
            throw NSError(domain: "private source details", code: 1)
        })
        preview.open()
        await #expect(throws: StatusPreviewError.unavailable) { try await preview.capture([region()], validating: { _ in true }) }
        #expect(sourceReads == 1)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: StatusPreviewError.cancelled) { try await preview.capture([region()], validating: { _ in true }) }
        }
        await task.value
        #expect(sourceReads == 1)
    }
}
