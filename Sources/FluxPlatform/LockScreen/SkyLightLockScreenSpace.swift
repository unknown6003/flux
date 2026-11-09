import AppKit
import CoreFoundation
import Darwin

// Ported from Flux 0.21.35: Sources/Flux/Notch/SkyLightLockScreenBridge.swift.
// The symbols, the space level (400) and the add-window call are unchanged.

/// The one special SkyLight space that keeps Flux windows above the lock
/// screen shield. A window level alone is not enough on current macOS.
///
/// This is a dynamic bridge, not a linked private framework. If Apple removes
/// or renames a symbol, `isLoadable` is false and the lock screen reports
/// "not available". Loading reads symbols only: the space is created on the
/// first `shared()` call, which happens when the screen first locks.
@MainActor
public final class SkyLightLockScreenSpace {
    public enum BridgeError: Error { case unavailable, spaceRejected, windowRejected }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetSpaceLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowToSpace = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    /// The notification-center-at-lock-screen tier: above the ordinary lock
    /// space (300), below Apple's boot and VoiceOver tiers.
    static let spaceLevel: Int32 = 400

    private struct Symbols {
        let mainConnection: MainConnection
        let createSpace: CreateSpace
        let setSpaceLevel: SetSpaceLevel?
        let showSpaces: ShowSpaces?
        let addWindowToSpace: AddWindowToSpace
    }

    private static var cachedSymbols: Symbols??
    private static var instance: SkyLightLockScreenSpace?

    private let symbols: Symbols
    private let connection: Int32
    private let space: Int32

    /// True when SkyLight and every required symbol load. No space is made.
    public static var isLoadable: Bool { loadSymbols() != nil }

    /// The process-wide space, created on first use and shown at level 400.
    public static func shared() throws -> SkyLightLockScreenSpace {
        if let instance { return instance }
        guard let symbols = loadSymbols() else { throw BridgeError.unavailable }
        let connection = symbols.mainConnection()
        guard connection != 0 else { throw BridgeError.unavailable }
        let space = symbols.createSpace(connection, 1, 0)
        guard space != 0 else { throw BridgeError.spaceRejected }
        _ = symbols.setSpaceLevel?(connection, space, spaceLevel)
        _ = symbols.showSpaces?(connection, [NSNumber(value: space)] as CFArray)
        let made = SkyLightLockScreenSpace(symbols: symbols, connection: connection, space: space)
        instance = made
        return made
    }

    private init(symbols: Symbols, connection: Int32, space: Int32) {
        self.symbols = symbols
        self.connection = connection
        self.space = space
    }

    /// Moves windows into the lock-screen space.
    public func add(windowIDs: [CGWindowID]) throws {
        let ids = windowIDs.filter { $0 != 0 }
        guard !ids.isEmpty else { return }
        let windows = ids.map { NSNumber(value: $0) } as CFArray
        guard symbols.addWindowToSpace(connection, space, windows, 7) == 0 else { throw BridgeError.windowRejected }
    }

    private static func loadSymbols() -> Symbols? {
        if let cachedSymbols { return cachedSymbols }
        let loaded = resolve()
        cachedSymbols = .some(loaded)
        return loaded
    }

    private static func resolve() -> Symbols? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self),
              let createSpace = symbol("SLSSpaceCreate", as: CreateSpace.self),
              let addWindowToSpace = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowToSpace.self)
        else { return nil }
        return Symbols(mainConnection: mainConnection, createSpace: createSpace,
                       setSpaceLevel: symbol("SLSSpaceSetAbsoluteLevel", as: SetSpaceLevel.self),
                       showSpaces: symbol("SLSShowSpaces", as: ShowSpaces.self),
                       addWindowToSpace: addWindowToSpace)
    }
}
