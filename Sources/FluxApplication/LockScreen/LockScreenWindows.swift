import AppKit
import FluxPlatform
import FluxUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/LockScreenPresenter.swift.
// The silhouette and card frames, the shielding level, the 0.4 s fade in,
// the 0.25 s fade out and the SkyLight space use are unchanged.

/// Puts lock-screen windows in a space that shows above the lock shield.
@MainActor public protocol LockScreenWindowBridge: AnyObject {
    func attach(windowIDs: [CGWindowID]) throws
    func detach() throws
}

/// The 0.21.35 bridge: one SkyLight space for the whole process. Detach has
/// nothing to undo, because the windows close right after it and the space
/// stays for the next lock, as it did in 0.21.35.
@MainActor public final class SkyLightWindowBridge: LockScreenWindowBridge {
    private let space: SkyLightLockScreenSpace

    public init() throws { space = try SkyLightLockScreenSpace.shared() }

    public func attach(windowIDs: [CGWindowID]) throws { try space.add(windowIDs: windowIDs) }
    public func detach() throws {}
}

enum LockScreenWindowError: Error { case cleanupPending, unavailable }

/// Where the lock-screen windows go: the physical notch and its screen.
struct LockScreenGeometry: Equatable {
    var notch: CGRect
    var screenFrame: CGRect
}

/// The card's vertical place, from the 0.21.35 presenter: centered at 28%
/// (media) or 21% (caption only) of the screen height from the bottom,
/// never below 20% or 10%, and never into the notch.
enum LockScreenWidgetPosition {
    static let mediaPreferredCenterFraction: CGFloat = 0.28
    static let mediaMinimumOriginFraction: CGFloat = 0.20
    static let companionPreferredCenterFraction: CGFloat = 0.21
    static let companionMinimumOriginFraction: CGFloat = 0.10

    static func originY(screenFrame: CGRect, notchHeight: CGFloat, widgetHeight: CGFloat, hasMedia: Bool) -> CGFloat {
        let center = hasMedia ? mediaPreferredCenterFraction : companionPreferredCenterFraction
        let minimum = hasMedia ? mediaMinimumOriginFraction : companionMinimumOriginFraction
        let preferredOriginY = screenFrame.minY + screenFrame.height * center - widgetHeight / 2
        let minimumOriginY = screenFrame.minY + screenFrame.height * minimum
        let maximumOriginY = screenFrame.maxY - notchHeight - 24 - widgetHeight
        return min(max(preferredOriginY, minimumOriginY), max(minimumOriginY, maximumOriginY))
    }
}

/// The silhouette over the notch and the optional card, created only by the
/// locked-session owner. A failed detach keeps the old bridge for an
/// explicit retry; no new space work starts while it is outstanding.
@MainActor final class LockScreenWindows {
    static let fadeInDuration: TimeInterval = 0.4
    static let fadeOutDuration: TimeInterval = 0.25

    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private let transport: @MainActor (LockScreenTransportAction) -> Void
    private var bridge: (any LockScreenWindowBridge)?
    private var silhouette: LockScreenPanel?
    private var card: LockScreenControlPanel?
    private var content: LockScreenContentController?
    private var geometry: LockScreenGeometry?
    private var fading: [NSWindow] = []
    private var fadeTask: Task<Void, Never>?
    private(set) var cleanupPending = false
    var appearance: NSAppearance? {
        didSet { [silhouette, card].forEach { $0?.appearance = appearance } }
    }

    init(makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
         transport: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.makeBridge = makeBridge; self.transport = transport
    }

    var isShowing: Bool { bridge != nil }

    func show(_ state: LockScreenContentState, geometry next: LockScreenGeometry) throws {
        guard !cleanupPending else { throw LockScreenWindowError.cleanupPending }
        finishFadeOut()
        if bridge != nil, geometry != next { try hide(animated: false) }
        if bridge == nil {
            let newBridge = try makeBridge()
            bridge = newBridge
            geometry = next
            let panel = LockScreenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            Self.configure(panel, ignoresMouseEvents: true)
            panel.appearance = appearance
            panel.contentView = LockScreenSilhouetteView(notchSize: next.notch.size)
            let width = max(next.notch.width, 1), height = max(next.notch.height, 8)
            panel.setFrame(NSRect(x: next.notch.midX - width / 2, y: next.screenFrame.maxY - height,
                                  width: width, height: height), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            silhouette = panel
            do { try attach(panel) } catch { try? hide(animated: false); throw error }
            Self.animate(panel, to: 1, duration: Self.fadeInDuration)
        }
        try syncCard(state)
    }

    /// Removes both windows. Animated: the bridge detaches now, the windows
    /// fade for 0.25 s and then close.
    func hide(animated: Bool) throws {
        let windows: [NSWindow] = [silhouette, card].compactMap { $0 }
        card?.ignoresMouseEvents = true
        content?.update(.empty)
        if bridge != nil {
            do { try bridge?.detach() } catch {
                // Keep the bridge for an explicit retry, but take the windows away now.
                cleanupPending = true
                windows.forEach { $0.orderOut(nil) }
                throw error
            }
        }
        cleanupPending = false
        bridge = nil
        geometry = nil
        silhouette = nil
        card = nil
        content = nil
        guard animated, !windows.isEmpty else {
            windows.forEach(Self.close)
            return
        }
        finishFadeOut()
        fading = windows
        windows.forEach { Self.animate($0, to: 0, duration: Self.fadeOutDuration) }
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration))
            guard let self, !Task.isCancelled else { return }
            self.finishFadeOut()
        }
    }

    private func finishFadeOut() {
        fadeTask?.cancel(); fadeTask = nil
        fading.forEach(Self.close)
        fading = []
    }

    private func syncCard(_ state: LockScreenContentState) throws {
        guard let geometry, let silhouette else { return }
        guard !state.isEmpty else {
            if let card { content?.update(.empty); Self.close(card) }
            card = nil; content = nil
            return
        }
        let panel: LockScreenControlPanel
        if let card {
            panel = card
            content?.update(state)
        } else {
            let controller = LockScreenContentController(state: state, onAction: transport)
            panel = LockScreenControlPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            Self.configure(panel, ignoresMouseEvents: false)
            panel.appearance = appearance
            panel.contentViewController = controller
            panel.alphaValue = silhouette.alphaValue
            card = panel; content = controller
        }
        let size = state.preferredSize
        let originY = LockScreenWidgetPosition.originY(screenFrame: geometry.screenFrame,
                                                       notchHeight: geometry.notch.height,
                                                       widgetHeight: size.height, hasMedia: state.showsMedia)
        panel.setFrame(NSRect(x: geometry.notch.midX - size.width / 2, y: originY,
                              width: size.width, height: size.height), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
        try attach(panel)
        if panel.alphaValue < 1, silhouette.alphaValue >= 1 {
            Self.animate(panel, to: 1, duration: Self.fadeInDuration)
        }
    }

    private func attach(_ window: NSWindow) throws {
        guard let bridge, let id = CGWindowID(exactly: window.windowNumber), id != 0 else {
            throw LockScreenWindowError.unavailable
        }
        try bridge.attach(windowIDs: [id])
    }

    /// One above the shielding level, as in 0.21.35.
    static var shieldedLevel: NSWindow.Level {
        let raw = CGShieldingWindowLevel()
        guard raw > 0 else { return .statusBar }
        return NSWindow.Level(rawValue: Int(raw) + 1)
    }

    private static func configure(_ panel: NSPanel, ignoresMouseEvents: Bool) {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = shieldedLevel
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = ignoresMouseEvents
    }

    private static func animate(_ window: NSWindow, to value: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = value
        }
    }

    private static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
        window.contentView = nil
        window.close()
    }
}

@MainActor final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class LockScreenControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
