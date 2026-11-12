import AppKit

struct StatusPreviewMenuWindow {
    let id: CGWindowID
    let application: String
    let displayID: CGDirectDisplayID
    let frame: CGRect

    func matchesMetadata(_ records: [[String: Any]], ownerPID: pid_t) -> Bool {
        let matches = records.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }
        guard matches.count == 1, let current = matches.first,
              (current[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
              (current[kCGWindowLayer as String] as? NSNumber)?.intValue == 24,
              let sharing = current[kCGWindowSharingState as String] as? NSNumber, sharing.intValue != 0,
              let bounds = current[kCGWindowBounds as String] as? NSDictionary,
              CGRect(dictionaryRepresentation: bounds) == frame else { return false }
        return true
    }
}

/// Reads only validated narrow MenuBarAgent surfaces. The owner supplies
/// screenshots; no display image or permission request belongs here.
@MainActor final class StatusMenuWindowPreview {
    private let windows: [StatusPreviewMenuWindow]
    private let displays: [StatusPreviewDisplay]
    private struct Surface {
        let frame: CGRect
        let image: CGImage
    }

    private var selected: [CGDirectDisplayID: Surface] = [:]
    private var attempted: Set<CGDirectDisplayID> = []
    private let takeImage: @MainActor (StatusPreviewMenuWindow) async throws -> CGImage

    init(windows: [StatusPreviewMenuWindow], displays: [StatusPreviewDisplay],
         capture: @escaping @MainActor (StatusPreviewMenuWindow) async throws -> CGImage) {
        self.windows = windows
        self.displays = displays
        self.takeImage = capture
    }

    func capture(_ plan: StatusPreviewPlan,
                 checking check: StatusPreviewSource.Check = { try Task.checkCancellation() }) async throws -> CGImage? {
        try checkCurrent(check)
        var result: CGImage?
        let matches = displays.filter { $0.id == plan.region.displayID }
        if matches.count == 1, let display = matches.first,
           Self.valid(display), Self.bounded(plan.region.frame),
           plan.region.frame.width <= 256, plan.region.frame.height <= 64,
           display.frame.contains(plan.region.frame),
           plan.region.frame.maxY <= display.frame.minY + 64,
           plan.pixelWidth == Int(ceil(plan.region.frame.width * display.pixelScale)),
           plan.pixelHeight == Int(ceil(plan.region.frame.height * display.pixelScale)),
           let candidates = validatedCandidates() {
            let eligible = (candidates[display.id] ?? []).filter { $0.frame.contains(plan.region.frame) }
            let surface = try await surface(for: display, candidates: eligible, checking: check)
            if let surface, surface.frame.contains(plan.region.frame) {
                let x = floor((plan.region.frame.minX - surface.frame.minX) * display.pixelScale)
                let y = floor((plan.region.frame.minY - surface.frame.minY) * display.pixelScale)
                let cropRect = CGRect(x: x, y: y, width: CGFloat(plan.pixelWidth), height: CGFloat(plan.pixelHeight))
                if CGRect(x: 0, y: 0, width: surface.image.width, height: surface.image.height).contains(cropRect),
                   let crop = surface.image.cropping(to: cropRect),
                   let owned = Self.copyRGBA(crop), Self.opaque(owned.pixels, percent: 90) {
                    result = StatusPreviewContent.copyVisibleImage(owned.image)
                }
            }
        }
        try checkCurrent(check)
        return result
    }

    private func checkCurrent(_ check: StatusPreviewSource.Check) throws {
        try Task.checkCancellation()
        try check()
    }

    private func surface(for display: StatusPreviewDisplay, candidates: [StatusPreviewMenuWindow],
                         checking check: StatusPreviewSource.Check) async throws -> Surface? {
        try checkCurrent(check)
        if let cached = selected[display.id] { return cached }
        guard attempted.insert(display.id).inserted else { return nil }
        for candidate in candidates {
            try checkCurrent(check)
            let image = try await takeImage(candidate)
            try checkCurrent(check)
            guard image.width == Int(ceil(candidate.frame.width * display.pixelScale)),
                  image.height == Int(ceil(candidate.frame.height * display.pixelScale)),
                  let owned = Self.copyRGBA(image),
                  Self.rendered(owned.pixels, width: image.width, height: image.height,
                                scale: display.pixelScale) else { continue }
            let surface = Surface(frame: candidate.frame, image: owned.image)
            selected[display.id] = surface
            return surface
        }
        return nil
    }

    private func validatedCandidates() -> [CGDirectDisplayID: [StatusPreviewMenuWindow]]? {
        guard windows.count <= 128, displays.count <= 32 else { return nil }
        var ids: Set<CGWindowID> = []
        var candidates: [CGDirectDisplayID: [StatusPreviewMenuWindow]] = [:]
        var pixels = 0
        for window in windows {
            guard window.id != 0 else { continue }
            guard ids.insert(window.id).inserted else { return nil }
            let matches = displays.filter { $0.id == window.displayID }
            guard matches.count == 1, let display = matches.first, Self.valid(display),
                  window.application == "com.apple.MenuBarAgent", Self.bounded(window.frame),
                  window.frame.width <= 16_384, (16...64).contains(window.frame.height),
                  window.frame.minX == display.frame.minX, window.frame.width == display.frame.width,
                  window.frame.minY == display.frame.minY,
                  display.frame.contains(window.frame) else { continue }
            candidates[display.id, default: []].append(window)
            guard candidates[display.id, default: []].count <= 4 else { return nil }
            pixels += Int(ceil(window.frame.width * display.pixelScale))
                * Int(ceil(window.frame.height * display.pixelScale))
            guard pixels <= 4_194_304 else { return nil }
        }
        return candidates
    }

    private static func valid(_ display: StatusPreviewDisplay) -> Bool {
        bounded(display.frame) && display.pixelScale.isFinite
            && display.pixelScale >= 1 && display.pixelScale <= 4
    }

    private static func bounded(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height, frame.maxX, frame.maxY]
            .allSatisfy { $0.isFinite && abs($0) <= 131_072 }
            && frame.width > 0 && frame.height > 0
    }

    private static func copyRGBA(_ image: CGImage) -> (image: CGImage, pixels: [UInt8])? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 65_536, height <= 256,
              width * height <= 4_194_304,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: width * height * 4))
        guard let owned = context.makeImage() else { return nil }
        return (owned, pixels)
    }

    private static func opaque(_ pixels: [UInt8], percent: Int) -> Bool {
        let count = pixels.count / 4
        guard count > 0 else { return false }
        var opaque = 0
        for index in 0..<count where pixels[index * 4 + 3] >= 250 { opaque += 1 }
        return opaque * 100 >= count * percent
    }

    private static func rendered(_ pixels: [UInt8], width: Int, height: Int, scale: CGFloat) -> Bool {
        guard opaque(pixels, percent: 75) else { return false }
        let inset = Int(ceil(3 * scale))
        guard width > 2 * inset, height > 2 * inset else { return false }
        var counts = [Int](repeating: 0, count: 4096)
        for y in inset..<(height - inset) {
            for x in inset..<(width - inset) {
                let offset = (y * width + x) * 4
                guard pixels[offset + 3] >= 250 else { continue }
                let key = Int(pixels[offset] >> 4) << 8 | Int(pixels[offset + 1] >> 4) << 4
                    | Int(pixels[offset + 2] >> 4)
                counts[key] += 1
            }
        }
        guard let background = counts.indices.max(by: { counts[$0] < counts[$1] }),
              counts[background] > 0 else { return false }
        let red = (background >> 8 & 15) * 17
        let green = (background >> 4 & 15) * 17
        let blue = (background & 15) * 17
        var different = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in inset..<(height - inset) {
            for x in inset..<(width - inset) {
                let offset = (y * width + x) * 4
                guard pixels[offset + 3] >= 250,
                      max(abs(Int(pixels[offset]) - red), abs(Int(pixels[offset + 1]) - green),
                          abs(Int(pixels[offset + 2]) - blue)) > 48 else { continue }
                different += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        let minimumSpan = Int(ceil(3 * scale))
        return different >= Int(ceil(16 * scale * scale))
            && maxX - minX + 1 >= minimumSpan && maxY - minY + 1 >= minimumSpan
    }
}
