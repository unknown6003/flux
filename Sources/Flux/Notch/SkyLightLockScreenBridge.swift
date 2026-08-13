import AppKit
import CoreFoundation
import Darwin

/// Small, optional bridge to the SkyLight private framework's special-space
/// APIs. A normal AppKit window level is not enough to make an overlay survive
/// the lock screen's shield on current macOS releases; assigning the window to
/// a system-level space is the missing part of that contract.
///
/// This is deliberately a dynamic bridge instead of a linked private-framework
/// dependency. If Apple removes or renames any symbol, Flux simply falls back
/// to its shielding-level panel and the rest of the app remains unaffected.
final class SkyLightLockScreenBridge {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetSpaceLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowToSpace = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let framework: UnsafeMutableRawPointer?
    private let mainConnection: MainConnection?
    private let createSpace: CreateSpace?
    private let setSpaceLevel: SetSpaceLevel?
    private let showSpaces: ShowSpaces?
    private let addWindowToSpace: AddWindowToSpace?
    private let connection: Int32
    private let space: Int32

    var isAvailable: Bool { connection != 0 && space != 0 && addWindowToSpace != nil }

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW)
        framework = handle

        guard let handle else {
            mainConnection = nil
            createSpace = nil
            setSpaceLevel = nil
            showSpaces = nil
            addWindowToSpace = nil
            connection = 0
            space = 0
            return
        }

        mainConnection = Self.symbol("SLSMainConnectionID", from: handle, as: MainConnection.self)
        createSpace = Self.symbol("SLSSpaceCreate", from: handle, as: CreateSpace.self)
        setSpaceLevel = Self.symbol("SLSSpaceSetAbsoluteLevel", from: handle, as: SetSpaceLevel.self)
        showSpaces = Self.symbol("SLSShowSpaces", from: handle, as: ShowSpaces.self)
        addWindowToSpace = Self.symbol(
            "SLSSpaceAddWindowsAndRemoveFromSpaces", from: handle, as: AddWindowToSpace.self)

        guard let mainConnection, let createSpace, let addWindowToSpace else {
            connection = 0
            space = 0
            return
        }

        let connection = mainConnection()
        let space = createSpace(connection, 1, 0)
        self.connection = connection
        self.space = space

        guard connection != 0, space != 0 else { return }

        // 400 is the notification-center-at-lock-screen tier. It is above the
        // ordinary lock-screen space (300) while leaving Apple's boot and
        // VoiceOver tiers alone.
        _ = setSpaceLevel?(connection, space, 400)
        let spaces = [NSNumber(value: space)] as CFArray
        _ = showSpaces?(connection, spaces)

        // Keep the required symbol referenced in this guard. The property is
        // intentionally otherwise used by `delegateWindow` below.
        _ = addWindowToSpace
    }

    /// Moves `window` into the dedicated lock-screen space. Returns false when
    /// the private bridge is unavailable or SkyLight rejects the operation.
    @discardableResult
    func delegateWindow(_ window: NSWindow) -> Bool {
        guard isAvailable,
              let addWindowToSpace,
              window.windowNumber > 0 else { return false }

        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        return addWindowToSpace(connection, space, windows, 7) == 0
    }

    private static func symbol<T>(_ name: String,
                                  from handle: UnsafeMutableRawPointer,
                                  as type: T.Type) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}
