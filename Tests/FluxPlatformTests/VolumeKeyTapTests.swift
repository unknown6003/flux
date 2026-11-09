import CoreGraphics
import Testing
@testable import FluxPlatform

struct VolumeKeyTapTests {
    @Test func fullKeyBurstFallsBackOnceAndDoesNotConsumeUnsupportedMute() {
        var queue = SoundKeyQueue()
        let volumeOnly = VolumeSnapshot(level: 0.5, muted: false, adjustable: true)
        #expect(!queue.offer(.mute, repeated: false, fine: false, output: volumeOnly))
        #expect(!queue.blocked)
        let output = VolumeSnapshot(level: 0.5, muted: false, adjustable: true, muteAdjustable: true)
        for _ in 0..<32 { #expect(queue.offer(.up, repeated: true, fine: false, output: output)) }
        #expect(queue.offer(.mute, repeated: true, fine: false, output: output))
        #expect(queue.commands.count == 32)
        #expect(!queue.offer(.up, repeated: true, fine: false, output: output))
        #expect(queue.blocked)
        #expect(queue.next() == .adjust(1 / 16))
        #expect(!queue.offer(.down, repeated: false, fine: false, output: output))
        queue.refresh()
        #expect(queue.offer(.down, repeated: false, fine: true, output: output))
        #expect(queue.commands.last == .adjust(-1 / 64))
    }

    @Test func anOutputCanSupportVolumeWithoutSupportingMute() {
        let output = VolumeSnapshot(level: 0.5, muted: false, adjustable: true, muteAdjustable: false)
        #expect(output.supports(.up))
        #expect(output.supports(.down))
        #expect(!output.supports(.mute))
    }

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
