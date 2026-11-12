import AppKit
@preconcurrency import ScreenCaptureKit

/// The caller must validate eligibility before creating a request. AX owner
/// frames alone do not establish that these pixels belong to a visible item.
public struct StatusPreviewRegion: Sendable {
    public let id: UUID
    public let displayID: CGDirectDisplayID
    /// Global Quartz screen points, with a top-left origin.
    public let frame: CGRect

    public init(id: UUID, displayID: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.displayID = displayID
        self.frame = frame
    }
}

@MainActor public struct StatusPreviewImage {
    public let id: UUID
    public let image: NSImage
}

public enum StatusPreviewError: Error, Equatable, Sendable {
    case closed, busy, permissionRequired, invalidRegion, budgetExceeded, unavailable, cancelled
}

/// One editor owns one instance. Call open when preview demand begins and close
/// before the editor closes. The caller owns and cancels its capture task.
/// Permission requests belong to the user's explicit action via PermissionAccess.
/// This adapter only checks permission. It retains no stream, timer or image cache.
@MainActor public final class StatusPreview {
    private var generation: UUID?
    private var capturing = false
    private let permission: @MainActor () -> Bool
    private let source: @MainActor () async throws -> StatusPreviewSource

    public convenience init() {
        self.init(permission: { PermissionAccess.status(.screenRecording) == .allowed },
                  source: { try await StatusPreviewSource.system() })
    }

    init(permission: @escaping @MainActor () -> Bool,
         source: @escaping @MainActor () async throws -> StatusPreviewSource) {
        self.permission = permission
        self.source = source
    }

    public func open() { generation = UUID() }

    /// SCScreenshotManager has no stop method. An outstanding single screenshot
    /// may finish, but its result is discarded and no next screenshot can start.
    public func close() { generation = nil }

    public func capture(_ regions: [StatusPreviewRegion],
                        validating validate: @escaping @MainActor (StatusPreviewRegion) async -> Bool) async throws -> [StatusPreviewImage] {
        guard let generation else { throw StatusPreviewError.closed }
        try check(generation)
        guard !capturing else { throw StatusPreviewError.busy }
        try StatusPreviewPlan.checkRequests(regions)
        guard !regions.isEmpty else { return [] }
        capturing = true
        defer { capturing = false }

        do {
            let source = try await source()
            try check(generation)
            let plans = try StatusPreviewPlan.make(regions, displays: source.displays)
            var images: [StatusPreviewImage] = []
            for plan in plans {
                try check(generation)
                guard await validate(plan.region) else { throw StatusPreviewError.invalidRegion }
                try check(generation)
                let image = try await source.capture(plan)
                try check(generation)
                guard await validate(plan.region) else { throw StatusPreviewError.invalidRegion }
                try check(generation)
                guard image.width == plan.pixelWidth, image.height == plan.pixelHeight else {
                    throw StatusPreviewError.unavailable
                }
                // macOS 27 still reports a frame for an item it does not draw:
                // one folded into the overflow, under the notch, or not yet
                // redrawn. That photo is one flat colour. The caller shows the
                // app icon instead.
                guard let ownedImage = StatusPreviewContent.copyVisibleImage(image) else { continue }
                images.append(.init(id: plan.region.id,
                                    image: NSImage(cgImage: ownedImage, size: plan.region.frame.size)))
            }
            return images
        } catch {
            try check(generation)
            if let fixed = error as? StatusPreviewError { throw fixed }
            throw StatusPreviewError.unavailable
        }
    }

    private func check(_ expected: UUID) throws {
        guard generation == expected, !Task.isCancelled else { throw StatusPreviewError.cancelled }
        guard permission() else { throw StatusPreviewError.permissionRequired }
    }
}

struct StatusPreviewDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let pixelScale: CGFloat
}

struct StatusPreviewPlan {
    let region: StatusPreviewRegion
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    static func checkRequests(_ regions: [StatusPreviewRegion]) throws {
        guard regions.count <= 128 else { throw StatusPreviewError.budgetExceeded }
        var ids: Set<UUID> = []
        for region in regions {
            guard ids.insert(region.id).inserted, bounded(region.frame),
                  region.frame.width <= 256, region.frame.height <= 64 else {
                throw StatusPreviewError.invalidRegion
            }
        }
    }

    static func make(_ regions: [StatusPreviewRegion],
                     displays: [StatusPreviewDisplay]) throws -> [StatusPreviewPlan] {
        try checkRequests(regions)
        guard displays.count <= 32 else { throw StatusPreviewError.unavailable }
        var pixels = 0
        return try regions.map { region in
            let matches = displays.filter { $0.id == region.displayID }
            guard matches.count == 1, let display = matches.first,
                  bounded(display.frame), display.pixelScale.isFinite,
                  display.pixelScale >= 1, display.pixelScale <= 4,
                  display.frame.contains(region.frame),
                  region.frame != display.frame,
                  region.frame.maxY <= display.frame.minY + 64 else {
                throw StatusPreviewError.invalidRegion
            }
            let width = Int(ceil(region.frame.width * display.pixelScale))
            let height = Int(ceil(region.frame.height * display.pixelScale))
            pixels += width * height
            guard pixels <= 4_194_304 else { throw StatusPreviewError.budgetExceeded }
            return .init(region: region,
                         sourceRect: CGRect(x: region.frame.minX - display.frame.minX,
                                            y: region.frame.minY - display.frame.minY,
                                            width: region.frame.width, height: region.frame.height),
                         pixelWidth: width, pixelHeight: height)
        }
    }

    private static func bounded(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
         frame.maxX, frame.maxY].allSatisfy { $0.isFinite && abs($0) <= 131_072 }
            && frame.size.width > 0 && frame.size.height > 0
    }
}

@MainActor struct StatusPreviewSource {
    let displays: [StatusPreviewDisplay]
    let capture: @MainActor (StatusPreviewPlan) async throws -> CGImage

    static func system() async throws -> StatusPreviewSource {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard content.displays.count <= 32 else { throw StatusPreviewError.unavailable }
        var filters: [CGDirectDisplayID: SCContentFilter] = [:]
        var displays: [StatusPreviewDisplay] = []
        for display in content.displays {
            guard filters[display.displayID] == nil else { throw StatusPreviewError.unavailable }
            // No window exclusions that could expose hidden content underneath.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if #available(macOS 14.2, *) { filter.includeMenuBar = true }
            filters[display.displayID] = filter
            displays.append(.init(id: display.displayID, frame: display.frame,
                                  pixelScale: CGFloat(filter.pointPixelScale)))
        }
        let displayFrames = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame) })
        return .init(displays: displays, capture: { plan in
            let id = plan.region.displayID
            guard let filter = filters[id], CGDisplayIsActive(id) != 0,
                  let expectedFrame = displayFrames[id], CGDisplayBounds(id) == expectedFrame else {
                throw StatusPreviewError.unavailable
            }
            let configuration = SCStreamConfiguration()
            // Always set the exact validated crop. Never expand to the display.
            configuration.sourceRect = plan.sourceRect
            configuration.width = plan.pixelWidth
            configuration.height = plan.pixelHeight
            configuration.showsCursor = false
            configuration.capturesAudio = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        })
    }
}

/// Tells a real item photo from an empty patch of menu bar.
enum StatusPreviewContent {
    /// True when fewer than 2% of pixels differ visibly from the most common
    /// colour. Every real item has a glyph, so it differs in far more.
    static func isBlank(_ image: CGImage) -> Bool {
        copyVisibleImage(image) == nil
    }

    /// Store an owned bitmap, never the screenshot provider's backing storage.
    static func copyVisibleImage(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 1_048_576,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: width * height * 4))
        guard !isBlank(rgba: pixels) else { return nil }
        return context.makeImage()
    }

    /// `rgba` holds premultiplied RGBA8 pixels.
    static func isBlank(rgba pixels: [UInt8]) -> Bool {
        let count = pixels.count / 4
        guard count > 0 else { return true }
        // Transparency is not a glyph. A black patch with a clear fringe
        // must not replace the app icon merely because its alpha varies.
        var counts: [UInt32: Int] = [:]
        for index in 0..<count {
            let base = index * 4
            let key = UInt32(pixels[base] >> 4) << 8 | UInt32(pixels[base + 1] >> 4) << 4
                | UInt32(pixels[base + 2] >> 4)
            counts[key, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return true }
        let reference = [Int(background >> 8 & 15) * 17, Int(background >> 4 & 15) * 17,
                         Int(background & 15) * 17]
        var different = 0
        for index in 0..<count {
            let base = index * 4
            let distance = max(abs(Int(pixels[base]) - reference[0]),
                               abs(Int(pixels[base + 1]) - reference[1]),
                               abs(Int(pixels[base + 2]) - reference[2]))
            if distance > 48 { different += 1 }
        }
        return different * 50 < count
    }
}
