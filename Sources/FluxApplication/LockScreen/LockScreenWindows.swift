import AppKit
import FluxPlatform
import FluxUI
import QuartzCore

/// Puts lock-screen windows in a space that shows above the lock shield.
@MainActor public protocol LockScreenWindowBridge: AnyObject {
    func attach(windowIDs: [CGWindowID]) throws
    func detach() throws
}

/// One SkyLight space for the whole process. Detach has nothing to undo,
/// because the windows close right after it and the space stays for the next lock.
@MainActor public final class SkyLightWindowBridge: LockScreenWindowBridge {
    private let space: SkyLightLockScreenSpace

    public init() throws { space = try SkyLightLockScreenSpace.shared() }

    public func attach(windowIDs: [CGWindowID]) throws { try space.add(windowIDs: windowIDs) }
    public func detach() throws {}
}

enum LockScreenWindowError: Error { case cleanupPending, unavailable }

/// Where the lock-screen windows go: the physical notch (if present) and its screen.
struct LockScreenGeometry: Equatable {
    var notch: CGRect
    var screenFrame: CGRect

    var hasNotch: Bool { notch.width > 0 && notch.height > 0 }
}

/// The card's vertical place:
/// - Minimal full-screen backdrop mode: centered in the lower Canape lane
///   (center at 19.8%, never below 12.4%, cleanly above the bottom unlock hint).
/// - Revealed native login mode (backdrop stays on screen with bottom band faded open):
///   elevated lane (center at 31%, minimum 23% for media; 25% / 22% for caption) so the
///   card stays cleanly above macOS's native avatar and password field.
/// - Overlay-only mode (no full-screen backdrop): higher lane (center at 28%,
///   minimum 20% for media; 21% / 10% for caption) so native login controls stay clear.
enum LockScreenWidgetPosition {
    static let mediaPreferredCenterFraction: CGFloat = 0.28
    static let mediaMinimumOriginFraction: CGFloat = 0.20
    static let companionPreferredCenterFraction: CGFloat = 0.21
    static let companionMinimumOriginFraction: CGFloat = 0.10
    static let minimalMediaPreferredCenterFraction: CGFloat = 0.198
    static let minimalMediaMinimumOriginFraction: CGFloat = 0.124
    static let minimalCompanionPreferredCenterFraction: CGFloat = 0.15
    static let minimalCompanionMinimumOriginFraction: CGFloat = 0.11
    static let revealedMediaPreferredCenterFraction: CGFloat = 0.31
    static let revealedMediaMinimumOriginFraction: CGFloat = 0.23
    static let revealedCompanionPreferredCenterFraction: CGFloat = 0.25
    static let revealedCompanionMinimumOriginFraction: CGFloat = 0.22

    static func originY(screenFrame: CGRect,
                        notchHeight: CGFloat,
                        widgetHeight: CGFloat,
                        hasMedia: Bool,
                        minimalBackdrop: Bool = false,
                        revealsNativeLogin: Bool = false) -> CGFloat {
        let center: CGFloat
        let minimum: CGFloat
        if minimalBackdrop && revealsNativeLogin {
            center = hasMedia ? revealedMediaPreferredCenterFraction : revealedCompanionPreferredCenterFraction
            minimum = hasMedia ? revealedMediaMinimumOriginFraction : revealedCompanionMinimumOriginFraction
        } else if minimalBackdrop {
            center = hasMedia ? minimalMediaPreferredCenterFraction : minimalCompanionPreferredCenterFraction
            minimum = hasMedia ? minimalMediaMinimumOriginFraction : minimalCompanionMinimumOriginFraction
        } else {
            center = hasMedia ? mediaPreferredCenterFraction : companionPreferredCenterFraction
            minimum = hasMedia ? mediaMinimumOriginFraction : companionMinimumOriginFraction
        }
        let preferredOriginY = screenFrame.minY + screenFrame.height * center - widgetHeight / 2
        var minimumOriginY = screenFrame.minY + screenFrame.height * minimum
        if minimalBackdrop && revealsNativeLogin {
            let revealClearHeight = LockScreenBackdropMetrics.nativeLoginReveal(for: screenFrame.height).clearHeight
            minimumOriginY = max(minimumOriginY, screenFrame.minY + revealClearHeight + 12)
        }
        let maximumOriginY = screenFrame.maxY - notchHeight - 24 - widgetHeight
        return min(max(preferredOriginY, minimumOriginY), max(minimumOriginY, maximumOriginY))
    }
}

/// Owns the lock-screen windows inside the SkyLight lock space:
/// - `backdrop`: full-screen mouse-transparent Liquid Glass clock + blurred-edge
///   artwork + depth cutout (when active)
/// - `silhouette`: physical camera-housing notch silhouette (when full-screen
///   backdrop is absent on a notched display)
/// - `card`: interactive Liquid Glass music player / live activity pill, layered
///   one window level above the backdrop
@MainActor final class LockScreenWindows {
    static let fadeInDuration: TimeInterval = 0.16
    static let fadeOutDuration: TimeInterval = 0.25

    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private let transport: @MainActor (LockScreenTransportAction) -> Void
    private var bridge: (any LockScreenWindowBridge)?
    private var silhouette: LockScreenPanel?
    private var backdropPanel: LockScreenPanel?
    private var backdropController: LockScreenBackdropController?
    private var prewarmedBackdropPanel: LockScreenPanel?
    private var prewarmedBackdropController: LockScreenBackdropController?
    private var prewarmedGeometry: LockScreenGeometry?
    private var card: LockScreenControlPanel?
    private var content: LockScreenContentController?
    private var geometry: LockScreenGeometry?
    private var lastCardState: LockScreenContentState = .empty
    private var lastBackdropImage: CGImage?
    private var lastMinimalBackdrop = false
    private var lastRevealsNativeLogin = false
    private var fading: [NSWindow] = []
    private var fadeTask: Task<Void, Never>?
    private var cardFadeInTask: Task<Void, Never>?
    private(set) var cleanupPending = false
    var appearance: NSAppearance? {
        didSet { [silhouette, backdropPanel, prewarmedBackdropPanel, card].forEach { $0?.appearance = appearance } }
    }

    init(makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
         transport: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.makeBridge = makeBridge
        self.transport = transport
    }

    var isShowing: Bool { bridge != nil }

    /// Prepares the full-screen backdrop panel off-screen while unlocked (without
    /// creating a SkyLight bridge or showing any window) so locking presents on
    /// the very first frame.
    func prewarmBackdrop(_ backdrop: LockScreenBackdropState, geometry next: LockScreenGeometry) {
        guard bridge == nil, backdrop.hasBackdrop else {
            discardPrewarmedBackdrop()
            return
        }
        if let panel = prewarmedBackdropPanel, let controller = prewarmedBackdropController {
            controller.update(backdrop)
            panel.appearance = appearance
            if prewarmedGeometry != next {
                panel.setFrame(next.screenFrame, display: false)
                panel.contentView?.frame = NSRect(origin: .zero, size: next.screenFrame.size)
                prewarmedGeometry = next
            }
            LockScreenBackdropController.prewarmClock(for: backdrop, screenSize: next.screenFrame.size)
            panel.contentView?.layoutSubtreeIfNeeded()
            return
        }
        let controller = LockScreenBackdropController(state: backdrop)
        let panel = LockScreenPanel(contentRect: next.screenFrame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered,
                                    defer: false)
        Self.configure(panel, level: Self.shieldedLevel, ignoresMouseEvents: true)
        panel.appearance = appearance
        panel.contentViewController = controller
        panel.setFrame(next.screenFrame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: next.screenFrame.size)
        LockScreenBackdropController.prewarmClock(for: backdrop, screenSize: next.screenFrame.size)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.alphaValue = 1
        prewarmedBackdropPanel = panel
        prewarmedBackdropController = controller
        prewarmedGeometry = next
    }

    func discardPrewarmedBackdrop() {
        if let panel = prewarmedBackdropPanel {
            prewarmedBackdropController?.update(.empty)
            Self.close(panel)
        }
        prewarmedBackdropPanel = nil
        prewarmedBackdropController = nil
        prewarmedGeometry = nil
    }

    func show(_ state: LockScreenContentState,
              backdrop: LockScreenBackdropState = .empty,
              geometry next: LockScreenGeometry) throws {
        guard !cleanupPending else { throw LockScreenWindowError.cleanupPending }
        finishFadeOut()
        let isInitialPresentation = (bridge == nil)
        if bridge != nil, geometry != next { try hide(animated: false) }
        lastBackdropImage = backdrop.backdrop
        if bridge == nil {
            let newBridge = try makeBridge()
            bridge = newBridge
            geometry = next
            try setupBaseWindow(geometry: next, backdrop: backdrop)
        } else {
            try syncBackdrop(backdrop, geometry: next)
        }
        lastCardState = state
        lastMinimalBackdrop = backdrop.hasBackdrop
        lastRevealsNativeLogin = backdrop.revealsNativeLogin
        try syncCard(state,
                     minimalBackdrop: backdrop.hasBackdrop,
                     revealsNativeLogin: backdrop.revealsNativeLogin,
                     immediate: isInitialPresentation)
        CATransaction.flush()
    }

    /// Removes all lock-screen windows. Animated: the bridge detaches now, the
    /// windows fade for 0.25 s and then close.
    func hide(animated: Bool) throws {
        let windows: [NSWindow] = [backdropPanel, silhouette, card].compactMap { $0 }
        card?.ignoresMouseEvents = true
        content?.update(.empty)
        backdropController?.update(.empty)
        if bridge != nil {
            do { try bridge?.detach() } catch {
                // Keep the bridge for an explicit retry, but take the windows away now.
                cleanupPending = true
                windows.forEach { $0.orderOut(nil) }
                throw error
            }
        }
        cleanupPending = false
        cancelCardFadeIn()
        bridge = nil
        geometry = nil
        silhouette = nil
        backdropPanel = nil
        backdropController = nil
        card = nil
        content = nil
        lastCardState = .empty
        lastBackdropImage = nil
        lastMinimalBackdrop = false
        lastRevealsNativeLogin = false
        guard animated else {
            finishFadeOut()
            windows.forEach(Self.close)
            return
        }
        guard !windows.isEmpty else { return }
        finishFadeOut()
        fading = windows
        windows.forEach { Self.animate($0, to: 0, duration: Self.fadeOutDuration) }
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration))
            guard !Task.isCancelled else { return }
            windows.forEach(Self.close)
            if let self, self.fading.elementsEqual(windows, by: ===) { self.fading = []; self.fadeTask = nil }
        }
    }

    private func finishFadeOut() {
        fadeTask?.cancel(); fadeTask = nil
        fading.forEach(Self.close)
        fading = []
    }

    private func cancelCardFadeIn() {
        cardFadeInTask?.cancel()
        cardFadeInTask = nil
    }

    private func setupBaseWindow(geometry next: LockScreenGeometry, backdrop: LockScreenBackdropState) throws {
        if backdrop.hasBackdrop {
            // Instant full opacity on lock so the original macOS lock screen never lingers underneath.
            try presentBackdrop(backdrop, geometry: next, initialAlpha: 1)
        } else if next.hasNotch {
            let panel = LockScreenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            Self.configure(panel, level: Self.shieldedLevel, ignoresMouseEvents: true)
            panel.appearance = appearance
            panel.contentView = LockScreenSilhouetteView(notchSize: next.notch.size)
            let width = max(next.notch.width, 1), height = max(next.notch.height, 8)
            panel.setFrame(NSRect(x: next.notch.midX - width / 2, y: next.screenFrame.maxY - height,
                                  width: width, height: height), display: true)
            panel.alphaValue = 1
            silhouette = panel
            do {
                // Attach to the SkyLight lock space before ordering front so the window
                // never flashes on the desktop space first.
                try attach(panel)
                panel.orderFrontRegardless()
            } catch {
                try? hide(animated: false)
                throw error
            }
        }
    }

    private func syncBackdrop(_ backdrop: LockScreenBackdropState, geometry next: LockScreenGeometry) throws {
        if backdrop.hasBackdrop {
            if let silhouette {
                Self.close(silhouette)
                self.silhouette = nil
            }
            if let backdropPanel, let backdropController {
                backdropController.update(backdrop)
                if backdropPanel.frame != next.screenFrame {
                    backdropPanel.setFrame(next.screenFrame, display: true)
                }
                if !backdropPanel.isVisible {
                    backdropPanel.orderFrontRegardless()
                    card?.orderFrontRegardless()
                }
            } else {
                try presentBackdrop(backdrop, geometry: next, initialAlpha: 1)
                card?.orderFrontRegardless()
            }
        } else if let backdropPanel {
            backdropController?.update(.empty)
            Self.close(backdropPanel)
            self.backdropPanel = nil
            self.backdropController = nil
            if next.hasNotch, silhouette == nil {
                try setupBaseWindow(geometry: next, backdrop: .empty)
            }
        }
    }

    private func presentBackdrop(_ backdrop: LockScreenBackdropState,
                                 geometry next: LockScreenGeometry,
                                 initialAlpha: CGFloat) throws {
        let controller: LockScreenBackdropController
        let panel: LockScreenPanel
        if let warmPanel = prewarmedBackdropPanel, let warmController = prewarmedBackdropController {
            prewarmedBackdropPanel = nil
            prewarmedBackdropController = nil
            prewarmedGeometry = nil
            controller = warmController
            panel = warmPanel
            controller.update(backdrop)
            panel.appearance = appearance
            panel.setFrame(next.screenFrame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: next.screenFrame.size)
        } else {
            controller = LockScreenBackdropController(state: backdrop)
            panel = LockScreenPanel(contentRect: next.screenFrame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered,
                                    defer: false)
            Self.configure(panel, level: Self.shieldedLevel, ignoresMouseEvents: true)
            panel.appearance = appearance
            panel.contentViewController = controller
            panel.setFrame(next.screenFrame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: next.screenFrame.size)
        }
        panel.alphaValue = initialAlpha
        backdropPanel = panel
        backdropController = controller
        do {
            // Join the SkyLight lock space before mapping onscreen to prevent a desktop-space flash.
            try attach(panel)
            panel.orderFrontRegardless()
        } catch {
            try? hide(animated: false)
            throw error
        }
    }

    private func syncCard(_ state: LockScreenContentState,
                          minimalBackdrop: Bool,
                          revealsNativeLogin: Bool,
                          immediate: Bool) throws {
        guard let geometry else { return }
        guard !state.isEmpty else {
            cancelCardFadeIn()
            if let card { content?.update(.empty); Self.close(card) }
            card = nil; content = nil
            return
        }
        let panel: LockScreenControlPanel
        let controller: LockScreenContentController
        let isNewCard: Bool
        if let existingCard = card, let existingController = content {
            panel = existingCard
            controller = existingController
            let size = existingController.preferredSize
            let enriched = enrichWithBackdropSlice(state, panelSize: size, geometry: geometry,
                                                   minimalBackdrop: minimalBackdrop,
                                                   revealsNativeLogin: revealsNativeLogin)
            controller.update(enriched)
            isNewCard = false
        } else {
            let initialSize = LockScreenMetrics.size(hasMedia: state.showsMedia,
                                                     hasActivity: state.showsActivity,
                                                     expandedOutputCount: 0)
            let enriched = enrichWithBackdropSlice(state, panelSize: initialSize, geometry: geometry,
                                                   minimalBackdrop: minimalBackdrop,
                                                   revealsNativeLogin: revealsNativeLogin)
            let madeController = LockScreenContentController(state: enriched, onAction: transport)
            madeController.onPreferredSizeChange = { [weak self] _ in
                guard let self else { return }
                self.layoutCardFrame()
            }
            panel = LockScreenControlPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            Self.configure(panel, level: Self.cardLevel, ignoresMouseEvents: false)
            panel.appearance = appearance
            panel.contentViewController = madeController
            panel.alphaValue = immediate ? 1 : 0
            card = panel
            content = madeController
            controller = madeController
            isNewCard = true
        }
        positionCard(panel, size: controller.preferredSize, geometry: geometry,
                     hasMedia: state.showsMedia, minimalBackdrop: minimalBackdrop,
                     revealsNativeLogin: revealsNativeLogin)
        if isNewCard || !panel.isVisible {
            // Join the SkyLight lock space before mapping onscreen so the card never flashes on the desktop.
            try attach(panel)
            panel.orderFrontRegardless()
        }
        if immediate {
            cancelCardFadeIn()
            panel.alphaValue = 1
        } else if isNewCard || panel.alphaValue < 1 {
            Self.animate(panel, to: 1, duration: Self.fadeInDuration)
            // Guarantee settlement if AppKit's window animator does not advance alpha
            // (e.g. non-active accessory windows or headless test runs on macOS 27).
            cancelCardFadeIn()
            cardFadeInTask = Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .seconds(Self.fadeInDuration))
                guard !Task.isCancelled, let self, let panel, self.card === panel else { return }
                panel.alphaValue = 1
                self.cardFadeInTask = nil
            }
        }
    }

    private func layoutCardFrame() {
        guard let card, let content, let geometry, !lastCardState.isEmpty else { return }
        let size = content.preferredSize
        positionCard(card, size: size, geometry: geometry,
                     hasMedia: lastCardState.showsMedia,
                     minimalBackdrop: lastMinimalBackdrop,
                     revealsNativeLogin: lastRevealsNativeLogin)
        let enriched = enrichWithBackdropSlice(lastCardState, panelSize: size, geometry: geometry,
                                               minimalBackdrop: lastMinimalBackdrop,
                                               revealsNativeLogin: lastRevealsNativeLogin)
        content.update(enriched)
    }

    private func cardFrame(for size: CGSize,
                           geometry: LockScreenGeometry,
                           hasMedia: Bool,
                           minimalBackdrop: Bool,
                           revealsNativeLogin: Bool) -> CGRect {
        let centerX = geometry.hasNotch ? geometry.notch.midX : geometry.screenFrame.midX
        let originY = LockScreenWidgetPosition.originY(screenFrame: geometry.screenFrame,
                                                       notchHeight: geometry.notch.height,
                                                       widgetHeight: size.height,
                                                       hasMedia: hasMedia,
                                                       minimalBackdrop: minimalBackdrop,
                                                       revealsNativeLogin: revealsNativeLogin)
        return CGRect(x: centerX - size.width / 2, y: originY, width: size.width, height: size.height)
    }

    private func enrichWithBackdropSlice(_ state: LockScreenContentState,
                                         panelSize: CGSize,
                                         geometry: LockScreenGeometry,
                                         minimalBackdrop: Bool,
                                         revealsNativeLogin: Bool) -> LockScreenContentState {
        guard minimalBackdrop, let backdrop = lastBackdropImage else {
            var plain = state
            plain.backdropSlice = nil
            plain.pillGlassImage = nil
            return plain
        }
        let fullFrame = cardFrame(for: panelSize, geometry: geometry, hasMedia: state.showsMedia,
                                  minimalBackdrop: minimalBackdrop, revealsNativeLogin: revealsNativeLogin)
        var enriched = state
        if state.showsMedia {
            let activityExtra = state.showsActivity ? (LockScreenMetrics.captionHeight + LockScreenMetrics.captionGap) : 0
            let mediaHeight = max(1, fullFrame.height - activityExtra)
            let mediaFrame = CGRect(x: fullFrame.minX,
                                    y: fullFrame.maxY - mediaHeight,
                                    width: fullFrame.width,
                                    height: mediaHeight)
            enriched.backdropSlice = LiquidGlassRenderer.shared.renderCardGlass(
                backdrop: backdrop,
                screenFrame: geometry.screenFrame,
                cardFrame: mediaFrame,
                cornerRadius: LockScreenMetrics.cardCornerRadius
            )
        } else {
            enriched.backdropSlice = nil
        }

        if state.showsActivity {
            let pillWidth = state.showsMedia ? min(LockScreenMetrics.activityOnlyWidth, fullFrame.width) : fullFrame.width
            let pillFrame = CGRect(x: fullFrame.midX - pillWidth * 0.5,
                                   y: fullFrame.minY,
                                   width: pillWidth,
                                   height: LockScreenMetrics.captionHeight)
            enriched.pillGlassImage = LiquidGlassRenderer.shared.renderPillGlass(
                backdrop: backdrop,
                screenFrame: geometry.screenFrame,
                pillFrame: pillFrame
            )
        } else {
            enriched.pillGlassImage = nil
        }
        return enriched
    }

    private func positionCard(_ panel: NSWindow,
                              size: CGSize,
                              geometry: LockScreenGeometry,
                              hasMedia: Bool,
                              minimalBackdrop: Bool,
                              revealsNativeLogin: Bool) {
        let frame = cardFrame(for: size, geometry: geometry, hasMedia: hasMedia,
                              minimalBackdrop: minimalBackdrop, revealsNativeLogin: revealsNativeLogin)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: size)
        }
    }

    private func attach(_ window: NSWindow) throws {
        guard let bridge, let id = CGWindowID(exactly: window.windowNumber), id != 0 else {
            throw LockScreenWindowError.unavailable
        }
        try bridge.attach(windowIDs: [id])
    }

    /// One above the shielding level for the base canvas/silhouette.
    static var shieldedLevel: NSWindow.Level {
        let raw = CGShieldingWindowLevel()
        guard raw > 0 else { return .statusBar }
        return NSWindow.Level(rawValue: Int(raw) + 1)
    }

    /// One level above `shieldedLevel` so the interactive Liquid Glass card
    /// always sits cleanly above the full-screen backdrop.
    static var cardLevel: NSWindow.Level {
        NSWindow.Level(rawValue: shieldedLevel.rawValue + 1)
    }

    private static func configure(_ panel: NSPanel, level: NSWindow.Level, ignoresMouseEvents: Bool) {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = level
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
