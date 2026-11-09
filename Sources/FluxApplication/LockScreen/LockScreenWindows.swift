import AppKit
import FluxUI

/// The OS adapter must own its space and prove its installed ABI and cleanup
/// contract before it is supplied here. Window IDs are 32-bit; private space
/// IDs must not be inferred from this public window identifier type.
@MainActor public protocol LockScreenWindowBridge: AnyObject {
    func attach(windowIDs: [CGWindowID]) throws
    func detach() throws
}

enum LockScreenWindowError: Error { case cleanupPending, unavailable }

/// Two local windows, created only by the locked-session owner. A failed
/// detach retains the old bridge for a bounded, explicit cleanup retry. It
/// cannot allocate another private space while that bridge is outstanding.
@MainActor final class LockScreenWindows {
    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private let transport: @MainActor (LockScreenTransportAction) -> Void
    private var bridge: (any LockScreenWindowBridge)?
    private var card: LockScreenControlWindow?
    private var silhouette: LockScreenSilhouetteWindow?
    private var content: LockScreenContentController?
    private var screenID: CGDirectDisplayID?
    private(set) var cleanupPending = false

    init(makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
         transport: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.makeBridge = makeBridge; self.transport = transport
    }

    func show(_ state: LockScreenContentState, on screen: NSScreen) throws {
        guard !cleanupPending else { throw LockScreenWindowError.cleanupPending }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let id else { throw LockScreenWindowError.unavailable }
        if screenID != nil, screenID != id { try hide() }
        if bridge == nil {
            let newBridge = try makeBridge()
            bridge = newBridge
            screenID = id
            let geometry = NotchWindowCoordinator.geometry(for: screen)
            let controller = LockScreenContentController(state: .empty, onAction: transport)
            let card = LockScreenControlWindow(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(card)
            card.contentViewController = controller
            card.ignoresMouseEvents = true
            self.card = card; content = controller
            guard let cardID = CGWindowID(exactly: card.windowNumber), cardID != 0 else {
                try? hide()
                throw LockScreenWindowError.unavailable
            }
            var ids = [cardID]
            if geometry.hasNotch {
                let silhouette = LockScreenSilhouetteWindow(contentRect: geometry.cameraRect,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                configure(silhouette)
                silhouette.ignoresMouseEvents = true
                silhouette.contentView = LockScreenSilhouetteView(notchSize: geometry.cameraRect.size)
                self.silhouette = silhouette
                guard let silhouetteID = CGWindowID(exactly: silhouette.windowNumber), silhouetteID != 0 else {
                    try? hide()
                    throw LockScreenWindowError.unavailable
                }
                ids.append(silhouetteID)
            }
            do { try newBridge.attach(windowIDs: ids) }
            catch {
                // Order out and clear content even when the OS rejects cleanup.
                // Do not replace the original error with a cleanup error.
                try? hide()
                throw error
            }
        }
        guard let card, let content else { throw LockScreenWindowError.unavailable }
        content.update(state)
        if state.isEmpty {
            card.ignoresMouseEvents = true
            card.orderOut(nil)
        } else {
            let size = state.preferredSize
            let top = screen.frame.maxY - max(screen.safeAreaInsets.top, 32) - 24
            card.setFrame(CGRect(x: screen.frame.midX - size.width / 2,
                                 y: top - size.height, width: size.width, height: size.height), display: true)
            card.ignoresMouseEvents = !state.showsMedia
            card.orderFrontRegardless()
        }
        silhouette?.orderFrontRegardless()
    }

    func hide() throws {
        card?.ignoresMouseEvents = true
        card?.orderOut(nil); silhouette?.orderOut(nil)
        content?.update(.empty)
        do { try bridge?.detach() }
        catch { cleanupPending = true; throw error }
        cleanupPending = false
        bridge = nil
        content = nil
        card?.contentViewController = nil
        card?.close(); card = nil
        silhouette?.close(); silhouette = nil
        screenID = nil
    }

    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.canBecomeVisibleWithoutLogin = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    }
}

@MainActor private final class LockScreenSilhouetteWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class LockScreenControlWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
