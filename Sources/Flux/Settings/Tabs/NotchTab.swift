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
                      subtitle: "Show a wing when headphones or other Bluetooth accessories connect or disconnect.",
                      isOn: $settings.notchActivityBluetoothEnabled)
            RowDivider()
            ToggleRow(title: "Upcoming event alerts",
                      subtitle: "Show a wing when a calendar event is starting within 10 minutes.",
                      isOn: $settings.notchActivityCalendarEventEnabled)
        }
    }

    /// M5: the volume/brightness HUD. `notchHudEnabled` is observe mode —
    /// CoreAudio-driven wings posted alongside whatever system bezel macOS
    /// still shows, needing no permission — and stays on by default.
    /// `notchHudInterceptEnabled` escalates to swallowing the keys outright
    /// (`MediaKeyInterceptor`) so only the notch HUD appears.
    ///
    /// The code-review fix here: the control is disabled only for turning the
    /// toggle ON without Accessibility granted (`NotchActivityRouter` would
    /// just silently keep falling back to observe mode anyway — see
    /// `applyHUDState`) — NOT while it's already ON and permission gets
    /// revoked later. The old `.disabled(... != .granted)` condition, with no
    /// exception for "already on," left the persisted toggle stuck ON with no
    /// way to switch it back OFF from this screen the moment Accessibility
    /// was revoked in System Settings — the user's only way out would've been
    /// editing the underlying default directly. `hudInterceptSubtitle` below
    /// covers the resulting "on, but not actually doing anything" state so
    /// that's visible rather than silent.
    private var hudCard: some View {
        FluxCard(title: "Volume & Brightness HUD") {
            ToggleRow(title: "Show in the notch",
                      subtitle: "Flash a volume/brightness wing in the notch when either changes.",
                      isOn: $settings.notchHudEnabled)
            if settings.notchHudEnabled {
                RowDivider()
                ToggleRow(title: "Replace the system overlay",
                          subtitle: hudInterceptSubtitle,
                          isOn: $settings.notchHudInterceptEnabled)
                    .disabled(!settings.notchHudInterceptEnabled && permissions.statuses[.accessibility] != .granted)
                RowDivider()
                PermissionRow(kind: .accessibility, title: "Accessibility access", permissions: permissions)
            }
        }
    }

    /// Reflects whether intercept mode is actually doing anything right now,
    /// not just whether the toggle is persisted ON — the toggle can be ON
    /// with Accessibility since revoked (see `hudCard`'s doc comment on why
    /// it stays operable in that state), and the subtitle should say so
    /// rather than keep promising behavior that isn't currently happening.
    private var hudInterceptSubtitle: String {
        guard settings.notchHudInterceptEnabled, permissions.statuses[.accessibility] != .granted else {
            return "Take over the volume/brightness keys so only the notch HUD appears — never the system bezel. Requires Accessibility below."
        }
        return "Inactive until Accessibility access is granted below — the system bezel still appears in the meantime."
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
