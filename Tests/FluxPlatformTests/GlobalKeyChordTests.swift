import Carbon.HIToolbox
import Testing
@testable import FluxPlatform

@Test func globalChordRequiresARealKeyAndOnlySupportedModifiers() {
    #expect(GlobalKeyChord(keyCode: 3, modifiers: UInt32(controlKey | optionKey | cmdKey)).isValid)
    #expect(!GlobalKeyChord(keyCode: 3, modifiers: UInt32(shiftKey)).isValid)
    #expect(!GlobalKeyChord(keyCode: 128, modifiers: UInt32(cmdKey)).isValid)
    #expect(!GlobalKeyChord(keyCode: 3, modifiers: UInt32(cmdKey) | 1).isValid)
}
