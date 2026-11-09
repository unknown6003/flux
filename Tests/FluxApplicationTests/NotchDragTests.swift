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
    /// The 0.21.35 drop rules: a file drag over the closed notch opens File
    /// Shelf, leaving without a drop closes only that panel, and a drop goes
    /// to the shelf copy job. The window is the only drop destination.
    @Test @MainActor func fileDragOpensTheShelfAndOnlyThatDragClosesIt() async throws {
        _ = NSApplication.shared
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        var dropped: [[URL]] = []
        var accept = true
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { widget in
                if widget == .shelf { return FileShelfWidgetController(state: .init(), onAction: { _ in }) }
                return CalendarWidgetController(state: .loading, onAction: { _ in })
            }, willDismissWidget: { _ in }, compactAction: { _ in },
            shelfDrop: { urls in dropped.append(urls); return accept }), resolveNotch: fixtureNotch)
        defer { owner.stop() }
        owner.start(widgets: [.shelf, .calendar])
        let window = try #require(NSApp.windows.compactMap { $0 as? NotchWindow }
            .first { !previous.contains(ObjectIdentifier($0)) })
        try await waitUntil { owner.viewModel.interactiveRect.width > 0 }
        let drag = FixtureDrag(window: window)
        defer { drag.cleanUp() }
        // The physical notch, in window coordinates.
        drag.draggingLocation = NSPoint(x: window.frame.width / 2, y: window.frame.height - 16)
        let key = NSApp.keyWindow
        #expect(window.draggingEntered(drag) == .copy)
        #expect(owner.presentation == .expanded(.shelf))
        #expect(!window.isKeyWindow)
        #expect(NSApp.keyWindow === key)
        window.draggingExited(drag)
        #expect(owner.presentation == .compact)

        #expect(window.draggingEntered(drag) == .copy)
        #expect(window.draggingUpdated(drag) == .copy)
        #expect(window.performDragOperation(drag))
        #expect(dropped.count == 1)
        // A drop keeps the shelf open, and a late exit does not close it.
        window.draggingExited(drag)
        #expect(owner.presentation == .expanded(.shelf))
        accept = false
        #expect(!window.performDragOperation(drag))
        owner.collapse()

        // Far from the notch, or with the shelf off, the drag is declined.
        drag.draggingLocation = NSPoint(x: 2, y: 2)
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(owner.presentation == .compact)
        drag.draggingLocation = NSPoint(x: window.frame.width / 2, y: window.frame.height - 16)
        owner.setWidgets([.calendar])
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(owner.presentation == .compact)
        owner.setWidgets([.shelf, .calendar])

        // Another open widget is never replaced by a drag.
        owner.expand(.calendar)
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(owner.presentation == .expanded(.calendar))
        owner.collapse()

        // A tile dragged out of this window is not taken back.
        drag.draggingSource = window.contentView
        #expect(window.draggingEntered(drag).isEmpty)
        drag.draggingSource = nil
        let text = FixtureDrag(window: window, file: false)
        defer { text.cleanUp() }
        text.draggingLocation = drag.draggingLocation
        _ = window.draggingEntered(text)
        #expect(!window.performDragOperation(text))
        owner.setSessionLocked(true)
        #expect(window.draggingEntered(drag).isEmpty)
        #expect(owner.presentation == .hidden)
        #expect(dropped.count == 2)
    }
}
