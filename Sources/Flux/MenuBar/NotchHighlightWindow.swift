import AppKit
import SwiftUI
import Combine

/// The SwiftUI content of the notch highlight: a soft amber wash that hugs the
/// notch's lower corners plus a pill badge that hangs just below it, pointing up.
/// It reads only Flux's own published overflow state — it never inspects another
/// app's icons — so it needs no Screen Recording or Accessibility permission.
private struct NotchHighlightView: View {
    @ObservedObject var arranger: MenuBarArranger
    let notchSize: CGSize
    let onActivate: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 3) {
            // Sits directly over the menu-bar strip at the notch and "lights it up".
            UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous)
                .fill(Theme.accentColor.opacity(pulse ? 0.55 : 0.28))
                .frame(width: notchSize.width, height: max(notchSize.height, 8))
                .shadow(color: Theme.accentColor.opacity(pulse ? 0.75 : 0.35),
                        radius: pulse ? 11 : 5, y: 2)

            // Badge hanging just below the notch, pointing up at what's stuck there.
            Button(action: onActivate) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(badgeText).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.accentInkColor))
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accentInkColor)
                        .offset(y: -6)
                }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help("Some menu-bar icons are clipped behind the notch — click to sort them")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var badgeText: String {
        let n = arranger.overflowIconCount
        return n > 0 ? "\(n) behind the notch" : "Hidden behind the notch"
    }
}

/// Owns a floating, non-activating overlay drawn over the notch while items the
/// user is trying to see are clipped behind it (`MenuBarArranger.notchOverflow`).
/// Shows/hides itself in response to that state; clicking it runs `onActivate`
/// (which opens the arrange drawer). Non-activating and confined to the notch's
/// own x-range so it never steals focus or blocks the live menu-bar items.
@MainActor
final class NotchHighlightWindowController {
    private let arranger: MenuBarArranger
    private let onActivate: () -> Void
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    init(arranger: MenuBarArranger, onActivate: @escaping () -> Void) {
        self.arranger = arranger
        self.onActivate = onActivate

        arranger.$notchOverflow
            .combineLatest(arranger.$overflowIconCount)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] over, _ in
                guard let self else { return }
                if over { self.show() } else { self.hide() }
            }
            .store(in: &cancellables)
    }

    private func show() {
        // Only meaningful on a notched screen; elsewhere there's nothing to hug.
        guard let screen = NSScreen.main, let notch = screen.notchRect else { hide(); return }
        let panel = self.panel ?? makePanel(notch: notch)
        self.panel = panel
        position(panel, notch: notch, screen: screen)
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel(notch: NSRect) -> NSPanel {
        let root = NotchHighlightView(arranger: arranger, notchSize: notch.size, onActivate: onActivate)
        let hosting = NSHostingView(rootView: root)

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar          // sit with the menu-bar items, above app windows
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        return panel
    }

    /// Centre the panel on the notch, top-anchored, spanning the notch width plus
    /// room below for the badge.
    private func position(_ panel: NSPanel, notch: NSRect, screen: NSScreen) {
        let width = max(notch.width, 210)
        let height = notch.height + 34   // badge hangs below the bar
        let origin = NSPoint(x: notch.midX - width / 2, y: screen.frame.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
