import AppKit
import CoreGraphics
import Foundation

/// Hardware media-key fallback for waking paused browser media sessions (such as
/// YouTube Music in Chromium/Ardia) when `MRMediaRemoteSendCommand` alone does
/// not resume playback. Posts the exact system-defined `NX_KEYTYPE_PLAY` (16)
/// key-down and key-up pair equivalent to pressing the F8 Play key.
@MainActor
public enum MediaKeyFallback {
    private static let playKeyCode = 16 // NX_KEYTYPE_PLAY
    private static let subtypeAuxControlButtons: Int16 = 8

    public static func sendPlayPauseKey() {
        post(keyDown: true)
        post(keyDown: false)
    }

    private static func post(keyDown: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xa00 : 0xb00)
        let data1 = (playKeyCode << 16) | ((keyDown ? 0xa : 0xb) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: subtypeAuxControlButtons,
            data1: data1,
            data2: -1
        ), let cgEvent = event.cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
}
