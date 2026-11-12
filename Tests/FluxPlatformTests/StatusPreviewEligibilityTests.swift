import AppKit
import Testing
@testable import FluxPlatform

struct StatusPreviewEligibilityTests {
    @Test func validatesTheExactOffscreenWindowInTheFreshAllWindowList() {
        let frame = CGRect(x: 0, y: 0, width: 1728, height: 33)
        let window = StatusPreviewMenuWindow(id: 900, application: "com.apple.MenuBarAgent",
                                            displayID: 1, frame: frame)
        let record: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 900),
            kCGWindowOwnerPID as String: NSNumber(value: 42),
            kCGWindowLayer as String: NSNumber(value: 24),
            kCGWindowSharingState as String: NSNumber(value: 1),
            kCGWindowIsOnscreen as String: false,
            kCGWindowBounds as String: frame.dictionaryRepresentation
        ]
        var all = (1...440).map { [kCGWindowNumber as String: NSNumber(value: $0)] as [String: Any] }
        all.insert(record, at: 200)
        #expect(window.matchesMetadata(all, ownerPID: 42))
        #expect(!window.matchesMetadata([], ownerPID: 42))
        #expect(!window.matchesMetadata(all + [record], ownerPID: 42))
        #expect(!window.matchesMetadata(all, ownerPID: 43))
        for (key, value) in [
            (kCGWindowLayer as String, NSNumber(value: 0) as Any),
            (kCGWindowSharingState as String, NSNumber(value: 0) as Any),
            (kCGWindowBounds as String, CGRect(x: 0, y: 1, width: 1728, height: 33).dictionaryRepresentation as Any)
        ] {
            var changed = record
            changed[key] = value
            #expect(!window.matchesMetadata([changed], ownerPID: 42))
        }
    }

    @Test func requiresOneDisplayAndASmallTopBandBeforeAnyHitTest() throws {
        let display = StatusPreviewDisplayBounds(id: 1, frame: .init(x: -1000, y: -100, width: 1000, height: 800))
        let frame = CGRect(x: -120, y: -95.5, width: 100, height: 24)
        let region = try #require(StatusInventory.previewRegion(frame: frame, displays: [display]))
        #expect(region.displayID == 1)
        #expect(region.frame == frame)
        #expect(StatusInventory.previewRegion(frame: frame, displays: [display, display]) == nil)
        let invalid = [
            CGRect(x: -120, y: -95.5, width: -20, height: 24),
            CGRect(x: -120, y: -95.5, width: 20, height: -24),
            CGRect(x: -120, y: -50, width: 20, height: 24),
            CGRect(x: -120, y: -95.5, width: 200, height: 24),
            CGRect(x: -500, y: -95.5, width: 257, height: 24),
            CGRect(x: CGFloat.nan, y: -95.5, width: 20, height: 24)
        ]
        for candidate in invalid {
            #expect(StatusInventory.previewRegion(frame: candidate, displays: [display]) == nil)
        }
    }
}
