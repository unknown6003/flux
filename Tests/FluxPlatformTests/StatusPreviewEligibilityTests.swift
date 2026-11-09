import Foundation
import Testing
@testable import FluxPlatform

struct StatusPreviewEligibilityTests {
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
