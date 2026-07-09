import AppKit
import SwiftUI

/// A SwiftUI mirror of a menu-bar **boundary marker**: a two-tone tag naming the
/// zone on each side of a divider, each half in its zone colour with an arrow
/// pointing into it (`◀ Hidden │ Shown ▶`). Used in the hint banner and the
/// Settings arrange panel so what the user sees painted in the bar is explained
/// pixel-for-pixel. Kept in exact visual sync with `ControlItem.markerImage`.
struct ArrangeBoundaryChip: View {
    let left: MenuBarSection
    let right: MenuBarSection

    var body: some View {
        HStack(spacing: 0) {
            half(left, pointingLeft: true)
            Rectangle().fill(Color.black.opacity(0.20)).frame(width: 1)
            half(right, pointingLeft: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func half(_ section: MenuBarSection, pointingLeft: Bool) -> some View {
        HStack(spacing: 3) {
            if pointingLeft {
                Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7, weight: .bold))
            }
            Text(section.displayName).font(.system(size: 11, weight: .bold))
            if !pointingLeft {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.zoneColor(section))
    }
}

/// The contents of the floating hint that appears just below the menu bar while
/// arranging. Its whole job is to make the (modifier-keyed, easy-to-miss) gesture
/// obvious *at the point of action* and to explain the coloured markers.
private struct ArrangeHintView: View {
    @ObservedObject var arranger: MenuBarArranger
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentInkColor)
                Text("Arranging your menu bar").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 16)
                Button("Done") { arranger.setArranging(false) }
                    .buttonStyle(.fluxProminent)
                    .fixedSize()
            }

            (Text("Hold ").foregroundStyle(.secondary)
             + Text("⌘").fontWeight(.bold)
             + Text(" and drag icons across the coloured markers in your bar:").foregroundStyle(.secondary))
                .font(.system(size: 12))

            HStack(spacing: 8) {
                ArrangeBoundaryChip(left: .hidden, right: .shown)
                Text("left → Hidden · right → Shown").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if showAlwaysHidden {
                HStack(spacing: 8) {
                    ArrangeBoundaryChip(left: .alwaysHidden, right: .hidden)
                    Text("left → Always-Hidden (reveal with ⌥)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
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
