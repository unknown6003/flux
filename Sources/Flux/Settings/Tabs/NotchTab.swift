import SwiftUI
import AppKit
import Foundation

/// Notch feature settings: master enable, how it opens, hover timing,
/// fullscreen visibility, and per-widget controls — Now Playing's enable
/// toggle plus a live status row (M1), and File Shelf's enable toggle plus
/// an auto-clear picker (M2).
struct NotchTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var permissions: PermissionCenter

    var body: some View {
        VStack(spacing: 18) {
            if NSScreen.builtInNotchedScreen == nil {
                noNotchNotice
            }
            generalCard
            if settings.notchEnabled {
                behaviorCard
                widgetsCard
                liveActivitiesCard
                hudCard
                experimentalCard
            }
        }
        .padding(20)
    }

    private var noNotchNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accentInkColor)
            Text("This Mac has no camera-housing notch. These settings still save, but there's nowhere for the notch panel to show.")
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceRaisedColor)
        )
    }

    private var generalCard: some View {
        FluxCard(title: "Notch") {
            ToggleRow(title: "Enable the notch panel",
                      subtitle: "Turns the camera housing into an expandable panel for live activities and widgets.",
                      isOn: $settings.notchEnabled)
        }
    }

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                RowText(title: "Open with",
                        subtitle: "Hover pauses briefly before expanding; click only opens on a tap.")
                Picker("", selection: $settings.notchExpansionTrigger) {
                    Text("Hover").tag(NotchExpansionTrigger.hover)
                    Text("Click").tag(NotchExpansionTrigger.click)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)

            if settings.notchExpansionTrigger == .hover {
                RowDivider()
                delayRow(title: "Open delay", value: $settings.notchHoverOpenDelay, range: 0.05...1.0)
                RowDivider()
                delayRow(title: "Close delay", value: $settings.notchHoverCloseDelay, range: 0.1...2.0)
            }
            RowDivider()
            ToggleRow(title: "Show while in fullscreen apps",
                      subtitle: "Keep the notch panel available over fullscreen windows.",
                      isOn: $settings.notchShowInFullscreen)
        }
    }

    private func delayRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Theme.textPrimaryColor)
            Slider(value: value, in: range).tint(Theme.accentColor)
            Text(String(format: "%.2fs", value.wrappedValue))
                .foregroundStyle(Theme.textSecondaryColor)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private var widgetsCard: some View {
        FluxCard(title: "Widgets") {
            ToggleRow(title: "Now Playing",
                      subtitle: "Show media controls and artwork for whatever's playing.",
                      isOn: $settings.notchNowPlayingEnabled)
            RowDivider()
            RowText(title: "Source", subtitle: nowPlaying.activeSourceName)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
            RowDivider()
            ToggleRow(title: "Duo view",
                      subtitle: "Show Now Playing and Calendar side by side when Now Playing is expanded (needs Calendar enabled too).",
                      isOn: $settings.notchDuoEnabled)
            RowDivider()
            ToggleRow(title: "File Shelf",
                      subtitle: "Drag files onto the notch to hold them; drag back out, AirDrop, or open anytime.",
                      isOn: $settings.notchShelfEnabled)
            if settings.notchShelfEnabled {
                RowDivider()
                shelfExpiryRow
            }
            RowDivider()
            ToggleRow(title: "Calendar",
                      subtitle: "Show your upcoming events, grouped into Today and Tomorrow.",
                      isOn: $settings.notchCalendarEnabled)
            if settings.notchCalendarEnabled {
                RowDivider()
                PermissionRow(kind: .calendar, title: "Calendar access", permissions: permissions)
            }
            RowDivider()
            ToggleRow(title: "Mirror",
                      subtitle: "A quick camera preview in the notch — the camera only ever runs while it's open.",
                      isOn: $settings.notchMirrorEnabled)
            if settings.notchMirrorEnabled {
                RowDivider()
                PermissionRow(kind: .camera, title: "Camera access", permissions: permissions)
            }
            RowDivider()
            ToggleRow(title: "Timers",
                      subtitle: "Quick countdown timers, right in the notch.",
                      isOn: $settings.notchTimersEnabled)
            RowDivider()
            ToggleRow(title: "Clipboard",
                      subtitle: "Keep a short history of what you copy, in memory only — never written to disk. Off by default; turn on to opt in.",
                      isOn: $settings.notchClipboardEnabled)
        }
    }

    /// Battery/Bluetooth wings (M3) — separate from `widgetsCard` since these
    /// aren't cycled widgets, they're transient activities that appear on
    /// their own triggers (plug/unplug, low battery, device connect).
    private var liveActivitiesCard: some View {
        FluxCard(title: "Live Activities") {
            ToggleRow(title: "Battery",
                      subtitle: "Show a wing when you plug in, unplug, or run low on battery.",
                      isOn: $settings.notchActivityBatteryEnabled)
            RowDivider()
            ToggleRow(title: "Bluetooth devices",
                      subtitle: "Show a wing when headphones or other Bluetooth accessories connect or disconnect, with a battery reading when one's reported. No permission needed.",
                      isOn: $settings.notchActivityBluetoothEnabled)
            RowDivider()
            ToggleRow(title: "Upcoming event alerts",
                      subtitle: "Show a wing when a calendar event is starting within 10 minutes.",
                      isOn: $settings.notchActivityCalendarEventEnabled)
            RowDivider()
            ToggleRow(title: "Timer alerts",
                      subtitle: "Show a wing (and play a sound) when a timer finishes, plus an ambient countdown while one's running.",
                      isOn: $settings.notchActivityTimerEnabled)
        }
    }

    /// The volume HUD — CoreAudio-driven wings posted alongside whatever
    /// system bezel macOS still shows, needing no permission. M11 removed
    /// the opt-in "intercept mode" escalation (which swallowed the keys
    /// outright via the now-deleted `MediaKeyInterceptor`, requiring
    /// Accessibility) along with the brightness half of this HUD entirely
    /// (brightness had no observe mode to fall back to) — this toggle is now
    /// the whole feature.
    private var hudCard: some View {
        FluxCard(title: "Volume HUD") {
            ToggleRow(title: "Show in the notch",
                      subtitle: "Shows volume changes next to the system overlay. No permission needed.",
                      isOn: $settings.notchHudEnabled)
        }
    }

    /// A dumping ground for spikes that ride on undocumented macOS behavior —
    /// kept visually and structurally separate (its own card, at the very
    /// bottom) from every other notch feature above, which are all built on
    /// documented, stable APIs. Right now that's just the lock-screen
    /// silhouette (see `LockScreenPresenter`'s own doc comment on exactly
    /// what it leans on and why it could break); a future spike would join
    /// it here rather than being folded into `widgetsCard`/`liveActivitiesCard`
    /// as if it carried the same stability guarantee.
    ///
    /// M9 (Alcove parity): the master toggle now reveals four sub-toggles —
    /// each independently gates one lock-screen sub-feature, but every one of
    /// them is meaningless (and never even observed — see
    /// `LockScreenPresenter.startObserving`) unless the master toggle above
    /// them is also on.
    private var experimentalCard: some View {
        FluxCard(title: "Experimental") {
            ToggleRow(title: "Show on the lock screen",
                      subtitle: "⚠️ Live media, notifications, and an optional unlock pill while the screen is locked. Relies on undocumented macOS behavior — may stop working, or misbehave, after any macOS update.",
                      isOn: $settings.notchLockScreenExperimentEnabled)
            if settings.notchLockScreenExperimentEnabled {
                RowDivider()
                ToggleRow(title: "Now Playing",
                          subtitle: "Show a media pill with artwork and title/artist while something's playing.",
                          isOn: $settings.notchLockScreenNowPlayingEnabled)
                RowDivider()
                ToggleRow(title: "Notifications",
                          subtitle: "Show the notch's current live activity (battery, Bluetooth, calendar, timer, ...) as a pill.",
                          isOn: $settings.notchLockScreenActivitiesEnabled)
                RowDivider()
                ToggleRow(title: "Unlock pill",
                          subtitle: "Show a \"Press any key to unlock\" pill below the notch.",
                          isOn: $settings.notchLockScreenUnlockPillEnabled)
                RowDivider()
                ToggleRow(title: "Play a sound on unlock",
                          subtitle: "Play a short sound the moment you unlock your Mac.",
                          isOn: $settings.notchLockScreenUnlockSoundEnabled)
            }
        }
    }

    /// Never (`0`), 1/3/7 days — mapped onto `notchShelfExpiryDays`'s raw
    /// `Double` via `ShelfExpiryOption`. Falls back to `.never` for any
    /// persisted value that isn't one of these four (there's no drift path
    /// that should produce one, but a stray value silently coercing to
    /// "never" is safer than the picker showing no selection at all).
    private var shelfExpiryRow: some View {
        HStack(spacing: 12) {
            RowText(title: "Auto-clear",
                    subtitle: "Automatically remove shelf items after a delay.")
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { ShelfExpiryOption(rawValue: settings.notchShelfExpiryDays) ?? .never },
                set: { settings.notchShelfExpiryDays = $0.rawValue }
            )) {
                ForEach(ShelfExpiryOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }
}

/// The "auto-clear" picker's discrete choices — a small, settings-UI-only
/// wrapper around the raw day counts `SettingsStore.notchShelfExpiryDays`
/// persists (and `ShelfStore.expiryInterval` ultimately consumes, converted
/// to seconds by the wiring agent).
private enum ShelfExpiryOption: Double, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .oneDay: return "1 day"
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        }
    }
}
