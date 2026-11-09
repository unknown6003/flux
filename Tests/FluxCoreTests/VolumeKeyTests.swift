import Testing
@testable import FluxCore

struct VolumeKeyTests {
    @Test func auxiliaryPacketsRecognizeOnlyVolumeKeysAndKnownPhases() {
        let up = VolumeKeyPacket(data1: 0x00000a00)
        #expect(up?.key == .up)
        #expect(up?.down == true)
        #expect(up?.repeated == false)
        let release = VolumeKeyPacket(data1: 0x00010b00)
        #expect(release?.key == .down)
        #expect(release?.down == false)
        let muteRepeat = VolumeKeyPacket(data1: 0x00070a01)
        #expect(muteRepeat?.key == .mute)
        #expect(muteRepeat?.repeated == true)
        #expect(VolumeKeyPacket(data1: 0x00060a00) == nil)
        #expect(VolumeKeyPacket(data1: 0x00000c00) == nil)
        #expect(VolumeKeyPacket(data1: -1) == nil)
    }
}
