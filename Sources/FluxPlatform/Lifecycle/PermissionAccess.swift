import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreBluetooth
import EventKit

public enum SystemPermission: CaseIterable, Sendable { case accessibility, screenRecording, calendar, camera, bluetooth }
public enum SystemAccess: Equatable, Sendable { case allowed, notAsked, notAllowed, unknown }

/// Status reads never construct a device or event store. Prompts are separate
/// calls, made only from the user's Allow or real-icon-preview action.
@MainActor public enum PermissionAccess {
    public static func status(_ permission: SystemPermission) -> SystemAccess {
        switch permission {
        case .accessibility: return AXIsProcessTrusted() ? .allowed : .notAllowed
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .allowed : .notAllowed
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .allowed
            case .notDetermined: return .notAsked
            case .denied, .restricted, .writeOnly: return .notAllowed
            @unknown default: return .unknown
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            case .denied, .restricted: return .notAllowed
            @unknown default: return .unknown
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .allowed
            case .notDetermined: return .notAsked
            case .denied, .restricted: return .notAllowed
            @unknown default: return .unknown
            }
        }
    }

    public static func request(_ permission: SystemPermission) async -> SystemAccess {
        switch permission {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .calendar: await CalendarPermissionRequest().request()
        case .camera:
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        case .bluetooth:
            // Flux reads paired accessories. It does not start a BLE scan just
            // to produce a permission prompt for an unrelated capability.
            openSettings(permission)
        }
        return status(permission)
    }

    public static func openSettings(_ permission: SystemPermission) {
        let anchor: String
        switch permission {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .calendar: anchor = "Privacy_Calendars"
        case .camera: anchor = "Privacy_Camera"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private actor CalendarPermissionRequest {
    private var store: EKEventStore?

    func request() async {
        let store = EKEventStore()
        self.store = store
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { _, _ in continuation.resume() }
        }
        self.store = nil
    }
}
