import AppKit
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@MainActor private final class FixtureDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint(x: 5, y: 5)
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSequenceNumber = 1
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow, file: Bool = true) {
        draggingDestinationWindow = window
        super.init()
        if file {
            draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/flux-drag-fixture.txt")])
        } else {
            draggingPasteboard.setString("fixture text", forType: .string)
        }
    }

    func slideDraggedImage(to point: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func cleanUp() { draggingPasteboard.releaseGlobally() }
}

@Suite(.serialized)
struct NotchDragTests {
    @Test @MainActor func nativeDragCallbacksCancelOnlyTheirOwnAutoOpenedPanel() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        var shelf: FileShelfWidgetController?
        var drops = 0
        var rootDrops = 0
        var ready = true
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { widget in
                if widget == .shelf {
                    let controller = FileShelfWidgetController(state: .init(items: [], status: .ready), onAction: {
                        if case .drop = $0 { rootDrops += 1 }
                    })
                    shelf = controller
                    return controller
                }
                let controller = NSViewController()
                controller.view = NSView()
                controller.view.heightAnchor.constraint(equalToConstant: 100).isActive = true
                return controller
            }, willDismissWidget: { _ in }, compactAction: { _ in },
            shelfDropReady: { ready }, shelfDrop: { _ in drops += 1; return true }))
        defer { owner.stop() }
        owner.start(screen: screen, widgets: [.shelf, .calendar])
        let window = try #require(NSApp.windows.compactMap { $0 as? NotchWindow }
            .first { !previous.contains(ObjectIdentifier($0)) })
        let drag = FixtureDrag(window: window)
        defer { drag.cleanUp() }
        let key = NSApp.keyWindow
        #expect(window.responds(to: NSSelectorFromString("draggingEnded:")))
        #expect(window.draggingEntered(drag) == .copy)
        #expect(owner.presentation == .expanded(.shelf))
        #expect(owner.dragOpenedSession == 1)
        #expect(!window.isKeyWindow)
        #expect(NSApp.keyWindow === key)
        // A transition between nested destinations keeps the panel open.
        window.draggingExited(drag)
        #expect(owner.presentation == .expanded(.shelf))
        let oldShelf = try #require(shelf)
        window.draggingEnded(drag)
        #expect(owner.presentation == .compact)
        #expect(owner.dragOpenedSession == nil)

        drag.draggingSequenceNumber = 2
        #expect(window.draggingEntered(drag) == .copy)
        // A delayed callback on a retained, removed root cannot close this visit.
        oldShelf.onDragSession?(.exited(session: nil, location: nil))
        oldShelf.onDragSession?(.ended(session: 2))
        #expect(owner.presentation == .expanded(.shelf))
        ready = false
        #expect(!window.performDragOperation(drag))
        #expect(drops == 0)
        window.draggingEnded(drag)
        // A rejected drop must still release its auto-open panel.
        #expect(owner.presentation == .compact)

        ready = true
        drag.draggingSequenceNumber = 3
        #expect(window.draggingEntered(drag) == .copy)
        #expect(window.performDragOperation(drag))
        #expect(drops == 1)
        window.draggingEnded(drag)
        #expect(owner.presentation == .expanded(.shelf))
        owner.collapse()
        drag.draggingSequenceNumber = 4
        #expect(window.draggingEntered(drag) == .copy)
        let root = try #require(shelf).view
        #expect(root.draggingEntered(drag) == .copy)
        #expect(root.performDragOperation(drag))
        root.draggingEnded(drag)
        window.draggingEnded(drag)
        #expect(owner.presentation == .expanded(.shelf))
        #expect(rootDrops == 1)
        #expect(drops == 1)
        owner.collapse()
        drag.draggingSequenceNumber = 5
        #expect(window.draggingEntered(drag) == .copy)
        try #require(shelf).view.draggingEnded(drag)
        #expect(owner.presentation == .compact)
        ready = false
        drag.draggingSequenceNumber = 6
        #expect(window.draggingEntered(drag) == .copy)
        #expect(window.draggingUpdated(drag).isEmpty)
        ready = true
        let updated = window.wantsPeriodicDraggingUpdates() ? window.draggingUpdated(drag) : []
        #expect(updated == .copy)
        let waitingShelf = try #require(shelf)
        waitingShelf.update(.init(items: [], status: .loading))
        let waitingRoot = waitingShelf.view
        #expect(waitingRoot.draggingEntered(drag).isEmpty)
        waitingShelf.update(.init(items: [], status: .ready))
        let rootUpdated = waitingRoot.wantsPeriodicDraggingUpdates() ? waitingRoot.draggingUpdated(drag) : []
        #expect(rootUpdated == .copy)
        window.draggingEnded(drag)
        #expect(owner.presentation == .compact)
        owner.expand(.calendar, focus: false)
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(owner.presentation == .expanded(.calendar))
        owner.collapse()
        drag.draggingSource = window.contentView
        #expect(window.draggingEntered(drag).isEmpty)
        drag.draggingSource = nil
        drag.draggingSourceOperationMask = .move
        #expect(window.draggingEntered(drag).isEmpty)
        drag.draggingSourceOperationMask = .copy
        let text = FixtureDrag(window: window, file: false)
        defer { text.cleanUp() }
        #expect(window.draggingEntered(text).isEmpty)
        owner.setSessionLocked(true)
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(!window.performDragOperation(drag))
        #expect(drops == 1)
        #expect(owner.presentation == .hidden)
    }

    @Test @MainActor func savedFullscreenBehaviorUpdatesTheRealWindowWithoutChangingSpacesFlags() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { _ in
                let controller = NSViewController()
                controller.view = NSView()
                controller.view.heightAnchor.constraint(equalToConstant: 100).isActive = true
                return controller
            }, willDismissWidget: { _ in }, compactAction: { _ in }))
        defer { owner.stop() }
        owner.setShowInFullscreen(false)
        owner.start(screen: screen, widgets: [.calendar])
        let window = try #require(NSApp.windows.compactMap { $0 as? NotchWindow }
            .first { !previous.contains(ObjectIdentifier($0)) })
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        let normal = window.collectionBehavior
        owner.setShowInFullscreen(true)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.subtracting(.fullScreenAuxiliary) == normal)
        owner.expand(.calendar, focus: false)
        #expect(owner.presentation == .expanded(.calendar))
        owner.setShowInFullscreen(false)
        #expect(owner.presentation == .compact)
        #expect(window.collectionBehavior == normal)
    }
}
