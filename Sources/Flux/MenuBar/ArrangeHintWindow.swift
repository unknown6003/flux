import AppKit
import SwiftUI

/// A SwiftUI mirror of a menu-bar **zone marker**: a solid pill in the zone's
/// colour with a left arrow and its name (`◀ Hidden`) — "everything to the left
/// of this marker is <zone>". Used in the hint banner and the Settings arrange
/// panel so what the user sees painted in the bar is explained pixel-for-pixel.
/// Kept in visual sync with `ControlItem.markerImage`.
struct ArrangeZoneChip: View {
    let zone: MenuBarSection

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7, weight: .bold))
            Text(zone.displayName).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.zoneColor(zone), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A deliberately loud reminder that the drag only works while ⌘ is held — the
/// one non-obvious part of arranging. macOS offers no way to move another app's
/// menu-bar icon without the ⌘ modifier, so Flux can't remove the requirement;
/// the next best thing is to make it impossible to miss. Shared by the floating
/// hint and the Settings arrange panel so the instruction reads identically.
struct CmdDragCallout: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("⌘")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accentInkColor)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surfaceRaisedColor)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.accentColor.opacity(0.55)))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Hold ⌘ Command while you drag")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text("Icons only move across the markers while ⌘ is down.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentWashColor)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accentColor.opacity(0.35)))
        )
    }
}

/// A right→left legend row: the zone's marker chip (as it appears in the bar)
/// next to a plain-language description. `zone == nil` is the Shown zone, which
/// owns no marker — it's just the area nearest the clock, so it gets an outlined
/// reference chip instead of a solid one.
struct ArrangeZoneLegendRow: View {
    let zone: MenuBarSection?
    let desc: String

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let zone {
                    ArrangeZoneChip(zone: zone)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 9, weight: .bold))
                        Text("Shown").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.zoneColor(.shown))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.zoneColor(.shown)))
                }
            }
            .frame(width: 116, alignment: .leading)
            Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// The contents of the floating hint that appears just below the menu bar while
/// arranging. Its whole job is to make the (modifier-keyed, easy-to-miss) gesture
/// obvious *at the point of action* and to explain the coloured markers.
private struct ArrangeHintView: View {
    @ObservedObject var arranger: MenuBarArranger
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentInkColor)
                Text("Arranging your menu bar").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 16)
                Button("Done") { arranger.setArranging(false) }
                    .buttonStyle(.fluxProminent)
                    .fixedSize()
            }

            CmdDragCallout()

            Text("Drag each icon into a zone — right to left in your bar:")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ArrangeZoneLegendRow(zone: nil, desc: "Stays visible, next to the clock")
                ArrangeZoneLegendRow(zone: .hidden, desc: "Tucked behind the chevron")
                if showAlwaysHidden {
                    ArrangeZoneLegendRow(zone: .alwaysHidden, desc: "Revealed only with ⌥ option")
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairlineColor)
        )
    }
}

/// Owns the floating, non-activating panel that shows `ArrangeHintView` below the
/// menu bar. Non-activating so it never steals focus — the user can keep
/// ⌘-dragging menu-bar icons while it's up, and still click its **Done** button.
@MainActor
final class ArrangeHintWindowController {
    private let arranger: MenuBarArranger
    private let showAlwaysHidden: () -> Bool
    private var panel: NSPanel?

    init(arranger: MenuBarArranger, showAlwaysHidden: @escaping () -> Bool) {
        self.arranger = arranger
        self.showAlwaysHidden = showAlwaysHidden
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let root = ArrangeHintView(arranger: arranger, showAlwaysHidden: showAlwaysHidden())
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        if let hosting = panel.contentView {
            hosting.setFrameSize(hosting.fittingSize)
            panel.setContentSize(hosting.fittingSize)
        }
        let size = panel.frame.size
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY,
                                NSStatusBar.system.thickness)
        // Tucked under the right side of the bar, where Flux's markers live.
        let x = min(screen.frame.maxX - size.width - 12,
                    screen.frame.midX - size.width / 2 + 120)
        let y = screen.frame.maxY - menuBarHeight - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
