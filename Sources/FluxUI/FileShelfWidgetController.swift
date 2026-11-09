import AppKit
import FluxCore
import SwiftUI

/// The fixed state of one shelf file. No spinner or progress value.
public enum FileShelfWidgetItemStatus: Equatable, Sendable {
    case ready
    /// The parent is still copying the file into the shelf.
    case copying
    /// The copy failed or the file is gone. The row can only be removed.
    case failed
}

/// One shelf row. The parent validates `dragURL` and owns the file behind it.
public struct FileShelfWidgetItem: Equatable {
    public var id: UUID
    public var name: String
    /// An app icon or a thumbnail the parent already made. Nil shows a document symbol.
    public var image: NSImage?
    /// The parent-owned file URL for drag out. Nil turns drag out off for this row.
    public var dragURL: URL?
    public var status: FileShelfWidgetItemStatus
    /// When the file was added. The tile shows its age.
    public var addedAt: Date?

    public init(id: UUID, name: String, image: NSImage? = nil, dragURL: URL? = nil,
                status: FileShelfWidgetItemStatus = .ready, addedAt: Date? = nil) {
        self.addedAt = addedAt
        self.id = id
        self.name = name
        self.image = image
        self.dragURL = dragURL
        self.status = status
    }
}

public enum FileShelfWidgetStatus: Equatable, Sendable {
    case ready
    /// The parent is reading the stored shelf.
    case loading
    /// The parent is working, for example copying a drop. New drops are refused.
    case busy
    /// The shelf cannot be read. Try Again sends `.retry`.
    case failed
}

public struct FileShelfWidgetState: Equatable {
    public var items: [FileShelfWidgetItem]
    public var status: FileShelfWidgetStatus

    public init(items: [FileShelfWidgetItem] = [], status: FileShelfWidgetStatus = .ready) {
        self.items = items
        self.status = status
    }
}

public enum FileShelfWidgetAction: Equatable, Sendable {
    /// The user dropped these file URLs on the widget. Sent once per drop.
    case drop([URL])
    case open(UUID)
    case showInFinder(UUID)
    case airDrop(UUID)
    case copy(UUID)
    case remove(UUID)
    /// The header Clear All button.
    case clearAll
    case retry
}

/// The File Shelf notch widget: the 0.21.35 SwiftUI tile strip. Drops land
/// on the notch window, not here. It does no file work: every change goes to
/// the parent.
@MainActor
public final class FileShelfWidgetController: NSViewController, NotchContentProviding {
    public private(set) var state: FileShelfWidgetState
    let model: ShelfNotchModel

    public init(state: FileShelfWidgetState, onAction: @escaping @MainActor (FileShelfWidgetAction) -> Void) {
        self.state = state
        model = ShelfNotchModel(state: state, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = NotchWidgetHost.make(notchContent())
    }

    public func notchContent() -> AnyView { AnyView(ShelfExpandedView(model: model)) }

    public func update(_ newState: FileShelfWidgetState) {
        guard newState != state else { return }
        state = newState
        model.state = newState
    }
}
