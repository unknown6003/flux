import AppKit
import SwiftUI
import Combine

/// The mouse-transparent glow drawn over the physical notch.
private struct NotchHighlightGlowView: View {
    let notchSize: CGSize
    @State private var pulse = false

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous)
            .fill(Theme.accentColor.opacity(pulse ? 0.55 : 0.28))
            .frame(width: notchSize.width, height: max(notchSize.height, 8))
            .shadow(color: Theme.accentColor.opacity(pulse ? 0.75 : 0.35),
                    radius: pulse ? 11 : 5, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// The only mouse-active part of the warning. Its window is fitted to this
/// view, so there is no clear status-level panel over another app's toolbar.
private struct NotchOverflowBadgeView: View {
    @ObservedObject var arranger: MenuBarArranger
    let onActivate: () -> Void

    var body: some View {
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
        .help("Some menu-bar icons are clipped behind the notch. Click to sort them.")
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var badgeText: String {
        let n = arranger.overflowIconCount
        return n > 0 ? "\(n) behind the notch" : "Hidden behind the notch"
    }
}

/// Owns a floating, non-activating overlay drawn over the notch while items the
/// user is trying to see are clipped behind it (`MenuBarArranger.notchOverflow`).
/// The glow and badge use separate windows. The glow ignores mouse events. The
/// mouse-active window fits the visible badge instead of covering the whole
/// top-center area.
@MainActor
final class NotchHighlightWindowController {
    enum Surface {
        case glow
        case badge
    }

    private let arranger: MenuBarArranger
    private let onActivate: () -> Void
    private var glowPanel: NSPanel?
    private var badgePanel: NSPanel?
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

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.arranger.notchOverflow else { return }
                self.show()
            }
            .store(in: &cancellables)
    }

    private func show() {
        // Only meaningful on a notched screen; elsewhere there's nothing to
        // hug. `builtInNotchedScreen`, NOT `NSScreen.main`: "main" is the
        // screen holding the key window, which for an accessory app is
        // wherever the user's frontmost app happens to be. On a MacBook
        // driving an external display, with focus on the external, that
        // resolved to a screen with no notch — so this overlay silently never
        // appeared even while icons genuinely were clipped behind the
        // built-in one. Every other notch consumer in the app already uses
        // `builtInNotchedScreen`; this was the odd one out.
        guard let screen = NSScreen.builtInNotchedScreen, let notch = screen.notchRect else { hide(); return }
        let glowPanel = self.glowPanel ?? makeGlowPanel(notch: notch)
        let badgePanel = self.badgePanel ?? makeBadgePanel()
        self.glowPanel = glowPanel
        self.badgePanel = badgePanel
        position(glowPanel: glowPanel, badgePanel: badgePanel, notch: notch, screen: screen)
        glowPanel.orderFrontRegardless()
        badgePanel.orderFrontRegardless()
    }

    private func hide() {
        glowPanel?.orderOut(nil)
        badgePanel?.orderOut(nil)
    }

    private func makeGlowPanel(notch: NSRect) -> NSPanel {
        let root = NotchHighlightGlowView(notchSize: notch.size)
        let hosting = NSHostingView(rootView: root)
        let panel = OverlayPanel.make(
            level: .statusBar,
            ignoresMouseEvents: Self.ignoresMouseEvents(for: .glow))
        panel.contentView = hosting
        return panel
    }

    private func makeBadgePanel() -> NSPanel {
        let root = NotchOverflowBadgeView(arranger: arranger, onActivate: onActivate)
        let hosting = NSHostingView(rootView: root)
        let panel = OverlayPanel.make(
            level: .statusBar,
            ignoresMouseEvents: Self.ignoresMouseEvents(for: .badge))
        panel.contentView = hosting
        return panel
    }

    private func position(glowPanel: NSPanel, badgePanel: NSPanel,
                          notch: NSRect, screen: NSScreen) {
        // Keep the old visual envelope so the pulsing shadow has room below
        // the notch. This window is safe at that size because it ignores input.
        let glowSize = NSSize(width: max(notch.width, 210), height: notch.height + 34)
        let glowOrigin = NSPoint(x: notch.midX - glowSize.width / 2,
                                 y: screen.frame.maxY - glowSize.height)
        glowPanel.setFrame(NSRect(origin: glowOrigin, size: glowSize), display: true)

        if let hosting = badgePanel.contentView {
            badgePanel.setContentSize(hosting.fittingSize)
        }
        badgePanel.setFrameOrigin(Self.badgeOrigin(notch: notch, badgeSize: badgePanel.frame.size))
    }

    /// Places the badge three points below the physical notch, centered on it.
    /// Kept pure so the self-test can lock down the mouse-active window's scope.
    static func badgeOrigin(notch: NSRect, badgeSize: NSSize) -> NSPoint {
        NSPoint(x: notch.midX - badgeSize.width / 2,
                y: notch.minY - 3 - badgeSize.height)
    }

    /// The large visual surface must never take input. Only the fitted badge
    /// is interactive. Both panel builders use this tested policy.
    static func ignoresMouseEvents(for surface: Surface) -> Bool {
        switch surface {
        case .glow: return true
        case .badge: return false
        }
    }
}
