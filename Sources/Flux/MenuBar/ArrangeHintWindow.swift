import AppKit
import SwiftUI

/// Shared colours for the arrange-mode zone tags, so the markers drawn in the
/// live menu bar (`ControlItem.markerImage`) and the SwiftUI chips in the hint
/// banner / Settings stay in exact visual sync.
enum ArrangeStyle {
    static func nsColor(for section: MenuBarSection) -> NSColor {
        switch section {
        case .shown: return .systemGreen
        case .hidden: return .systemOrange
        case .alwaysHidden: return .systemRed
        }
    }

    static func color(for section: MenuBarSection) -> Color {
        Color(nsColor: nsColor(for: section))
    }
}

/// A SwiftUI mirror of a menu-bar zone marker: a coloured tag with a left arrow
/// and the zone name. Used in the hint banner and the Settings arrange panel so
/// the user can connect what they see in the bar with what it means.
struct ArrangeMarkerChip: View {
    let section: MenuBarSection
    var showArrow = true

    var body: some View {
        HStack(spacing: 3) {
            if showArrow {
                Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7, weight: .bold))
            }
            Text(section.displayName).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(ArrangeStyle.color(for: section), in: RoundedRectangle(cornerRadius: 4))
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
                Text("Arranging your menu bar").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 16)
                Button("Done") { arranger.setArranging(false) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            (Text("Hold ").foregroundStyle(.secondary)
             + Text("⌘").fontWeight(.bold)
             + Text(" and drag your menu-bar icons across the markers:").foregroundStyle(.secondary))
                .font(.system(size: 12))

            HStack(spacing: 8) {
                ArrangeMarkerChip(section: .hidden)
                Text("drop icons to its left → Hidden").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if showAlwaysHidden {
                HStack(spacing: 8) {
                    ArrangeMarkerChip(section: .alwaysHidden)
                    Text("to its left → Always-Hidden").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ArrangeMarkerChip(section: .shown, showArrow: false)
                Text("anything right of Hidden stays Shown").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
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
