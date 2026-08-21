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
    @EnvironmentObject private var clipboardMonitor: ClipboardMonitor
    @State private var confirmingClipboardClear = false

    var body: some View {
        VStack(spacing: 18) {
            if NSScreen.builtInNotchedScreen == nil {
                noNotchNotice
            }
            generalCard
            if settings.notchEnabled {
                behaviorCard
                widgetsCard
                widgetOrderCard
                liveActivitiesCard
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
            ToggleRow(title: "Clipboard",
                      subtitle: "Keep a short history of what you copy. Off by default; turn it on to opt in.",
                      isOn: $settings.notchClipboardEnabled)
            RowDivider()
            ToggleRow(title: "Save clipboard history",
                      subtitle: "Keep text and URLs between launches. Flux skips images, files, and concealed or temporary copies.",
                      isOn: $settings.notchClipboardPersistenceEnabled)
            if settings.notchClipboardPersistenceEnabled {
                RowDivider()
                HStack {
                    RowText(title: "Saved entries",
                            subtitle: "Stored only on this Mac. The file is limited and private to your user account.")
                    Spacer(minLength: 12)
                    Button("Clear History", role: .destructive) {
                        confirmingClipboardClear = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warningColor)
                    .disabled(clipboardMonitor.entries.isEmpty)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClipboardClear,
                            titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { clipboardMonitor.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the current history and its saved copy.")
        }
    }

    // MARK: Cycle order

    /// `settings.notchWidgetOrder` has been persisted and honoured since M1 —
    /// `NotchWidgetRegistry.order` drives the whole swipe cycle from it — but
    /// nothing in the app could ever change it, so it could only ever hold
    /// the factory default. This card is that missing half.
    ///
    /// Up/down buttons rather than drag-to-reorder: these rows live inside a
    /// plain `VStack` in a `ScrollView`, not a `List`, so `.onMove` isn't
    /// available without restructuring the whole tab — and buttons are
    /// keyboard- and VoiceOver-reachable for free, which a drag handle isn't.
    private var widgetOrderCard: some View {
        FluxCard(title: "Cycle order") {
            RowText(title: "Swipe order",
                    subtitle: "The order left/right swipes move through the widgets. Disabled widgets keep their place but are skipped.")
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
            ForEach(orderedWidgetIDs, id: \.self) { id in
                RowDivider()
                widgetOrderRow(id)
            }
        }
    }

    /// The persisted order, resolved and made total: unknown raw values (a
    /// widget removed from a later build) are dropped, and any registered
    /// widget the saved array never mentioned is appended — matching how
    /// `NotchWidgetRegistry.enabledWidgets` treats the same list, so what's
    /// shown here is what actually cycles.
    private var orderedWidgetIDs: [WidgetID] {
        var seen = Set<WidgetID>()
        var result: [WidgetID] = []
        for raw in settings.notchWidgetOrder {
            guard let id = WidgetID(rawValue: raw), seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in WidgetID.allCases where !seen.contains(id) { result.append(id) }
        return result
    }

    private func widgetOrderRow(_ id: WidgetID) -> some View {
        let ids = orderedWidgetIDs
        let index = ids.firstIndex(of: id) ?? 0
        return HStack(spacing: 10) {
            Image(systemName: id.symbol)
                .frame(width: 18)
                .foregroundStyle(Theme.textSecondaryColor)
            Text(id.title)
                .foregroundStyle(Theme.textPrimaryColor)
            if !isEnabled(id) {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer(minLength: 0)
            orderButton("chevron.up", label: "Move \(id.title) earlier", enabled: index > 0) {
                move(id, to: index - 1)
            }
            orderButton("chevron.down", label: "Move \(id.title) later", enabled: index < ids.count - 1) {
                move(id, to: index + 1)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private func orderButton(_ symbol: String, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Theme.accentInkColor : Theme.textSecondaryColor.opacity(0.4))
        .accessibilityLabel(label)
    }

    private func move(_ id: WidgetID, to destination: Int) {
        var ids = orderedWidgetIDs
        guard let from = ids.firstIndex(of: id), ids.indices.contains(destination) else { return }
        ids.remove(at: from)
        ids.insert(id, at: destination)
        // Written as raw values because that's what `SettingsStore` persists
        // — see `notchWidgetOrder`'s own doc comment on why it's `[String]`.
        settings.notchWidgetOrder = ids.map(\.rawValue)
    }

    private func isEnabled(_ id: WidgetID) -> Bool {
        settings[keyPath: id.enabledSettingKey]
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
            ToggleRow(title: "Timer live display",
                      subtitle: "Show a live countdown wing while a timer is running, and an alert when it finishes.",
                      isOn: $settings.notchActivityTimerEnabled)
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
