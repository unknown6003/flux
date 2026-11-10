import CoreFoundation
import Darwin
import Foundation

/// Tells whether a display currently shows a fullscreen Space.
///
/// macOS 27 cannot drop the menu bar down in a fullscreen Space while a
/// MenuBarAgent assessment assertion is active, so the hider lifts it there.
/// This is a dynamic SkyLight read, the same symbols yabai and Flux 0.21.35's
/// lock bridge load. If a symbol is missing, the answer is `nil`.
public enum FullscreenSpaces {
    /// The SkyLight Space type of a fullscreen app's Space.
    static let fullscreenType = 4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private nonisolated(unsafe) static let symbols: (MainConnection, CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    /// True when any display shows a fullscreen Space, nil when unreadable.
    public static func anyActive() -> Bool? {
        guard let (main, copy) = symbols else { return nil }
        let connection = main()
        guard connection != 0, let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        return containsFullscreen(displays)
    }

    /// Reads `SLSCopyManagedDisplaySpaces` output: one dictionary per display,
    /// each with a "Current Space" dictionary whose "type" is the Space type.
    static func containsFullscreen(_ displays: [[String: Any]]) -> Bool {
        displays.contains { display in
            guard let current = display["Current Space"] as? [String: Any],
                  let type = (current["type"] as? NSNumber)?.intValue else { return false }
            return type == fullscreenType
        }
    }
}
