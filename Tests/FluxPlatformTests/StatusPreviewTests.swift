import AppKit
import Testing
@testable import FluxPlatform

@MainActor struct StatusPreviewTests {
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
        return try #require(context.makeImage())
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
        await #expect(throws: StatusPreviewError.closed) { try await preview.capture([region()]) }
        preview.open()
        await #expect(throws: StatusPreviewError.permissionRequired) { try await preview.capture([region()]) }
        #expect(sourceReads == 0)

        let allowed = StatusPreview(permission: { true }, source: {
            sourceReads += 1
            throw StatusPreviewError.unavailable
        })
        allowed.open()
        await #expect(throws: StatusPreviewError.budgetExceeded) {
            try await allowed.capture((0..<129).map { _ in region() })
        }
        #expect(try await allowed.capture([]).isEmpty)
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
                await #expect(throws: StatusPreviewError.busy) { try await preview.capture([region()]) }
                return try image(plan)
            })
        })
        let preview = try #require(owner)
        preview.open()
        let images = try await preview.capture(requests)
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
            try await preview.capture([region(), region()])
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
            try await preview.capture([region(), region()])
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
            try await preview.capture([region(), region(displayID: 8)])
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
                try await preview.capture([region(), region()])
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
        await #expect(throws: StatusPreviewError.unavailable) { try await preview.capture([region()]) }
        #expect(sourceReads == 1)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: StatusPreviewError.cancelled) { try await preview.capture([region()]) }
        }
        await task.value
        #expect(sourceReads == 1)
    }
}
