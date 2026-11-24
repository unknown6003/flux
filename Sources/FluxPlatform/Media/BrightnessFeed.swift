import CoreGraphics
import Darwin
import Foundation
import FluxCore

/// Reads and adjusts the built-in display brightness via macOS `DisplayServices`
/// (`DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`), which works
/// on both Apple Silicon and Intel MacBooks. Safely degrades to unavailable on
/// systems or displays that do not expose brightness control.
public final class BrightnessController: @unchecked Sendable {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: GetBrightnessFn?
    private let setFn: SetBrightnessFn?

    public init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getFn = nil
            setFn = nil
            return
        }
        getFn = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightnessFn.self) }
        setFn = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightnessFn.self) }
    }

    public var isAvailable: Bool {
        getFn != nil && setFn != nil && targetDisplayID() != nil
    }

    public func current() -> BrightnessSnapshot? {
        guard let getFn, let display = targetDisplayID() else { return nil }
        var level: Float = 0
        guard getFn(display, &level) == 0, level.isFinite else { return nil }
        return BrightnessSnapshot(level: level, adjustable: setFn != nil)
    }

    public func adjust(by delta: Float) -> BrightnessSnapshot? {
        guard delta.isFinite, let getFn, let setFn, let display = targetDisplayID() else { return nil }
        var currentLevel: Float = 0
        guard getFn(display, &currentLevel) == 0, currentLevel.isFinite else { return nil }
        let target = min(max(currentLevel + delta, 0), 1)
        guard setFn(display, target) == 0 else { return nil }
        var readBack: Float = target
        if getFn(display, &readBack) == 0, readBack.isFinite {
            return BrightnessSnapshot(level: readBack, adjustable: true)
        }
        return BrightnessSnapshot(level: target, adjustable: true)
    }

    private func targetDisplayID() -> CGDirectDisplayID? {
        let main = CGMainDisplayID()
        if main != kCGNullDirectDisplay, CGDisplayIsBuiltin(main) != 0 {
            return main
        }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return main != kCGNullDirectDisplay ? main : nil
    }
}
