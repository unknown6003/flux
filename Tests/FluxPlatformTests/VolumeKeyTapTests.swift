import CoreGraphics
import Testing
@testable import FluxPlatform

struct VolumeKeyTapTests {
    @Test @MainActor func filterDispatchPreservesConsumedEventsWithoutPostingInput() throws {
        let event = try #require(CGEvent(source: nil))
        let token = UInt.max
        #expect(VolumeTapCallbacks.actions[token] == nil)
        VolumeTapCallbacks.actions[token] = { _, _ in nil }
        defer { VolumeTapCallbacks.actions[token] = nil }
        #expect(VolumeTapCallbacks.dispatch(token: token, type: .keyDown, event: event) == nil)
        let passed = VolumeTapCallbacks.dispatch(token: 0, type: .keyDown, event: event)
        #expect(passed?.takeUnretainedValue() === event)
    }
}
