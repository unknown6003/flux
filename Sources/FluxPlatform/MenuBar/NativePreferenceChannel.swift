import CoreFoundation
import Darwin
import Foundation
import FluxCore

public enum NativePreferenceError: Error { case unavailable, synchronizationFailed, invalidValue, verificationFailed }

/// Container-aware CFPreferences ABI verified on macOS27.0.1. No instance
/// is created until a capability probe asks for it. Calls stay off the UI actor.
/// This interface remains gated on physical and recovery acceptance.
public actor NativePreferenceChannel {
    private typealias Copy = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias SetValue = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias Synchronize = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) -> DarwinBoolean
    private let copy: Copy
    private let set: SetValue
    private let synchronize: Synchronize
    private let key = "trackedApplications" as CFString
    private let domain = "group.com.apple.controlcenter" as CFString
    private let container: CFString

    public init() throws {
        guard #available(macOS 27.0, *),
              let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let copy = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
              let set = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
              let synchronize = dlsym(handle, "_CFPreferencesSynchronizeWithContainer") else {
            throw NativePreferenceError.unavailable
        }
        self.copy = unsafeBitCast(copy, to: Copy.self)
        self.set = unsafeBitCast(set, to: SetValue.self)
        self.synchronize = unsafeBitCast(synchronize, to: Synchronize.self)
        container = (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString
    }

    public func read() throws -> NativeVisibilityDocument {
        try sync()
        guard let pointer = copy(Self.ptr(key), Self.ptr(domain), Self.ptr(kCFPreferencesCurrentUser),
                                 Self.ptr(kCFPreferencesAnyHost), Self.ptr(container)) else {
            throw NativePreferenceError.invalidValue
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
        guard CFGetTypeID(value) == CFDataGetTypeID() else { throw NativePreferenceError.invalidValue }
        let data = unsafeDowncast(value, to: CFData.self)
        guard CFDataGetLength(data) <= 8 * 1024 * 1024 else { throw NativePreferenceError.invalidValue }
        return try NativeVisibilityDocument(data: data as Data)
    }

    public func apply(_ lease: NativeVisibilityLease, executableURLs: [URL]) throws {
        let fresh = try read()
        try write(fresh.applying(lease, executableURLs: executableURLs))
        guard try read().inspect(lease.application, executableURLs: executableURLs).allowed == lease.written else {
            throw NativePreferenceError.verificationFailed
        }
    }

    public func restore(_ lease: NativeVisibilityLease, executableURLs: [URL]) throws {
        let fresh = try read()
        let entry = try fresh.inspect(lease.application, executableURLs: executableURLs)
        if entry.allowed != lease.original {
            try write(fresh.restoring(lease, executableURLs: executableURLs))
        }
        guard try read().inspect(lease.application, executableURLs: executableURLs).allowed == lease.original else {
            throw NativePreferenceError.verificationFailed
        }
    }

    private func write(_ document: NativeVisibilityDocument) throws {
        let retained = Unmanaged.passRetained(document.data as CFData)
        set(Self.ptr(key), UnsafeRawPointer(retained.toOpaque()), Self.ptr(domain),
            Self.ptr(kCFPreferencesCurrentUser), Self.ptr(kCFPreferencesAnyHost), Self.ptr(container))
        retained.release()
        try sync()
    }

    private func sync() throws {
        guard synchronize(Self.ptr(domain), Self.ptr(kCFPreferencesCurrentUser), Self.ptr(kCFPreferencesAnyHost),
                          Self.ptr(container)).boolValue else { throw NativePreferenceError.synchronizationFailed }
    }

    private static func ptr(_ value: CFString) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque())
    }
}
