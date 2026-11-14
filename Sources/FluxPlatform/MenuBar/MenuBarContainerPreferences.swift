import Foundation

final class MenuBarContainerPreferences {
    private typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetValue = @convention(c) (CFString, CFTypeRef?, CFString, CFString, CFString, CFString) -> Void
    private typealias Sync = @convention(c) (CFString, CFString, CFString, CFString) -> Bool
    private let copy: Copy?
    private let set: SetValue?
    private let sync: Sync?
    private let domain: CFString
    private let key: CFString
    private let container: CFString

    init(domain: String, key: String, container: URL) {
        self.domain = domain as CFString; self.key = key as CFString; self.container = container.path as CFString
        let library = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW)
        copy = library.flatMap { dlsym($0, "_CFPreferencesCopyValueWithContainer") }.map { unsafeBitCast($0, to: Copy.self) }
        set = library.flatMap { dlsym($0, "_CFPreferencesSetValueWithContainer") }.map { unsafeBitCast($0, to: SetValue.self) }
        sync = library.flatMap { dlsym($0, "_CFPreferencesSynchronizeWithContainer") }.map { unsafeBitCast($0, to: Sync.self) }
    }

    func read() -> CFTypeRef? {
        guard let copy, let sync, sync(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container) else { return nil }
        return copy(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)?.takeRetainedValue()
    }

    func write(_ value: CFTypeRef?) -> Bool {
        guard let set, let sync else { return false }
        set(key, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        return sync(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
    }
}
