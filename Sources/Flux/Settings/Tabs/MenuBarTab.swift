import SwiftUI
import AppKit

/// The live menu-bar preview, Arrange Mode entry point, section toggles, the
/// auto re-hide behavior, and icon appearance — everything about how the
/// three-zone menu bar itself looks and behaves.
struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(spacing: 18) {
            MenuBarPreview(showAlwaysHidden: settings.showAlwaysHiddenSection)
                .padding(.horizontal, 4)
            layoutCard
            behaviorCard
            appearanceCard
        }
        .padding(20)
    }

    // MARK: Menu bar layout

    /// The one place the user assigns icons to zones. Enters Arrange Mode, which
    /// reveals labeled markers in the live bar so ⌘-drag becomes obvious.
    private var layoutCard: some View {
        FluxCard(title: "Menu Bar Layout") {
            ArrangeRows()
        }
    }

    // MARK: Behavior

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            ToggleRow(title: "Always-Hidden zone",
                      subtitle: "A second zone revealed only with ⌥ (option).",
                      isOn: $settings.showAlwaysHiddenSection)
            RowDivider()
            ToggleRow(title: "Compact menu-bar spacing",
                      subtitle: "Tightens the gap around every icon so more fit beside the notch. Affects all apps; full effect after your next login.",
                      isOn: $settings.compactMenuBarSpacing)
            RowDivider()
            ToggleRow(title: "Auto re-hide",
                      subtitle: "Collapse again a moment after revealing.",
                      isOn: $settings.autoRehide)
            if settings.autoRehide {
                RowDivider()
                SliderRow(value: $settings.autoRehideDelay, range: 2...30)
            }
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        FluxCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                RowText(title: "Menu bar icon",
                        subtitle: "The glyph Flux shows in your menu bar.")
                Picker("", selection: $settings.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }
}

/// The interactive contents of the "Menu Bar Layout" card. Toggles Arrange Mode
/// and, while it's active, spells out exactly how the ⌘-drag zoning works so the
/// live markers in the bar aren't a mystery.
private struct ArrangeRows: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if arranger.isArranging {
                arrangingContent
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .animation(.easeInOut(duration: 0.15), value: arranger.isArranging)
    }

    @State private var confirmingReset = false

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowText(title: "Organize your menu bar",
                    subtitle: "Choose which icons stay Shown, tuck into Hidden, or go Always-Hidden.")
            Button {
                arranger.setArranging(true)
            } label: {
                Label("Arrange Menu Bar…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.fluxProminent)

            Button("Reset layout…") { confirmingReset = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.textSecondaryColor)
                .confirmationDialog("Reset your menu bar layout?",
                                    isPresented: $confirmingReset,
                                    titleVisibility: .visible) {
                    Button("Reset and Relaunch", role: .destructive) {
                        ControlItem.resetLayout()
                        Relaunch.now()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every icon goes back to Shown and Flux's markers return to their default places. Flux relaunches to apply it. Your other settings are untouched.")
                }
        }
    }

    private var arrangingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(Theme.accentColor).frame(width: 8, height: 8)
                Text("Arranging your menu bar").font(.body.weight(.semibold))
            }
            // The coloured markers are live in your menu bar right now — mirror them
            // here so it's obvious what each one means and which way to drag.
            CmdDragCallout()
            // Both flags: the notch warning is meaningless outside Arrange Mode.
            if arranger.isArranging && arranger.overflowsNotch {
                NotchOverflowWarning()
            }
            if settings.showAlwaysHiddenSection {
                ArrangeFocusPicker()
            }
            Text("Drag each icon into a zone — right to left in your bar:")
                .font(.callout).foregroundStyle(Theme.textSecondaryColor)
            VStack(alignment: .leading, spacing: 8) {
                ArrangeZoneLegendRow(zone: nil, desc: "Stays visible, next to the clock")
                // Only list a zone whose marker is actually on the bar for this
                // focus: .hiddenAlwaysHidden drops the ◀Hidden marker; .shownHidden
                // tucks Always-Hidden away entirely.
                if arranger.focus != .hiddenAlwaysHidden {
                    ArrangeZoneLegendRow(zone: .hidden, desc: "Tucked behind the chevron")
                }
                if settings.showAlwaysHiddenSection && arranger.focus != .shownHidden {
                    ArrangeZoneLegendRow(zone: .alwaysHidden, desc: "Revealed only with ⌥ option")
                }
            }
            Text("Click Done — or the ✓ that replaced the Flux icon — to apply.")
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            Button {
                arranger.setArranging(false)
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.fluxProminent)
        }
    }
}

/// Incremental arranging: choose which edge to sort, so users with more icons than
/// fit beside the notch can work one boundary at a time — Flux collapses the zone
/// that isn't involved to free the most space. Shown only when Always-Hidden exists.
private struct ArrangeFocusPicker: View {
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sort which edge")
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            Picker("", selection: $arranger.focus) {
                ForEach(MenuBarArranger.Focus.allCases) { focus in
                    Text(focus.title).tag(focus)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(arranger.focus.explanation)
                .font(.caption2).foregroundStyle(Theme.textSecondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown while arranging when the current edge's marker can't sit clear of the
/// notch, so that edge is out of reach. Gives an honest reason and — when a
/// less-crowded edge exists — a one-tap way to switch to it.
private struct NotchOverflowWarning: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    /// Switching to the Shown ↔ Hidden edge tucks Always-Hidden away, freeing the
    /// most space — only useful when we're not already on that edge.
    private var canFocusShownHidden: Bool {
        settings.showAlwaysHiddenSection && arranger.focus != .shownHidden
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(title)
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimaryColor)
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if !MenuBarSpacing.isCompact {
                Text("Tip: turn on Compact menu-bar spacing (above) to free room for every icon.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accentInkColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canFocusShownHidden {
                Button {
                    arranger.focus = .shownHidden
                } label: {
                    Label("Sort Shown ↔ Hidden", systemImage: "arrow.left.to.line")
                }
                .buttonStyle(.fluxProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.4)))
        )
    }

    private var title: String {
        arranger.focus == .shownHidden
            ? "Too many icons beside the notch"
            : "This edge won't fit beside the notch"
    }

    /// "about N icons" phrasing for the cascade coaching; `Lead` capitalises only
    /// the first letter for sentence starts.
    private var overCount: String {
        let n = arranger.overflowIconCount
        return n > 0 ? "about \(n) icon\(n == 1 ? "" : "s")" : "a few icons"
    }
    private var overCountLead: String { overCount.prefix(1).uppercased() + overCount.dropFirst() }

    private var message: String {
        switch arranger.focus {
        case .all:
            return "\(overCountLead) more than fit beside the notch, so the Always-Hidden edge is clipped out of sight. Sort one edge at a time — start with Shown ↔ Hidden — or quit a few menu-bar apps."
        case .hiddenAlwaysHidden:
            // Coach the cascade: the edge is behind the notch, but each icon dragged
            // across ◀Always frees roughly its own width and pulls the marker back
            // into view, so only the first move is blind.
            return "\(overCountLead) sit to the right of ◀Always, so it's clipped behind the notch. You can still drag one from Hidden all the way to the far left — past the notch — to drop it into Always-Hidden. Each icon you move brings ◀Always back into view, so the next is easier."
        case .shownHidden:
            return "Even with Always-Hidden tucked away, your Shown and Hidden icons don't fit beside the notch. Quit a few menu-bar apps, or arrange on a display without a notch."
        }
    }
}

// MARK: - Live menu-bar preview

/// A faux menu bar that teaches the zone model at a glance and reflects the
/// Always-Hidden toggle live. Each zone's dots carry its marker colour so the
/// preview, the live markers, and the legend all read as one system.
private struct MenuBarPreview: View {
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if showAlwaysHidden {
                    zone(count: 2, tint: Theme.zoneColor(.alwaysHidden))
                    glyph("chevron.left.2")
                }
                zone(count: 3, tint: Theme.zoneColor(.hidden))
                glyph("chevron.left", accent: true)
                zone(count: 2, tint: Theme.zoneColor(.shown))
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surfaceRaisedColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.hairlineColor)
                    )
            )

            HStack(spacing: 14) {
                legend(section: .shown, label: "Shown")
                legend(section: .hidden, label: "Hidden")
                if showAlwaysHidden {
                    legend(section: .alwaysHidden, label: "Always-Hidden")
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private func zone(count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(tint).frame(width: 11, height: 11)
            }
        }
    }

    private func glyph(_ name: String, accent: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? Theme.accentInkColor : Theme.textSecondaryColor)
    }

    private func legend(section: MenuBarSection, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.zoneColor(section)).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
