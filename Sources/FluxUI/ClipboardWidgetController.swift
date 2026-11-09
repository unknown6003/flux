import AppKit
import SwiftUI
import FluxCore

public enum ClipboardWidgetKind: String, Equatable, Sendable {
    case text, url, color, file, image, other
}

/// A copied color as sRGB values, 0...1.
public struct ClipboardWidgetColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// One clipboard row. The parent keeps the payload and copies it back.
/// The row holds only a short preview and an optional small image.
public struct ClipboardWidgetItem: Equatable {
    /// Longest preview the row keeps, in characters.
    public static let maximumPreviewLength = 200

    public var id: UUID
    /// At most `maximumPreviewLength` characters. `init` cuts longer text.
    public var preview: String
    public var kind: ClipboardWidgetKind
    /// A small thumbnail or file icon the parent already made. Never the full image.
    public var image: NSImage?
    public var color: ClipboardWidgetColor?
    /// False when the parent no longer has the payload. Copy is then off.
    public var hasPayload: Bool
    /// A link the parent checked. Open in Browser shows only for http and https.
    public var link: URL?
    /// When the item was copied. The row shows its age.
    public var capturedAt: Date?

    public init(id: UUID, preview: String, kind: ClipboardWidgetKind, image: NSImage? = nil,
                color: ClipboardWidgetColor? = nil, hasPayload: Bool = true, link: URL? = nil,
                capturedAt: Date? = nil) {
        self.capturedAt = capturedAt
        self.id = id
        self.preview = String(preview.prefix(Self.maximumPreviewLength))
        self.kind = kind
        self.image = image
        self.color = color
        self.hasPayload = hasPayload
        self.link = link
    }

    var webLink: URL? {
        guard let link, let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
              link.host?.isEmpty == false else { return nil }
        return link
    }
}

public struct ClipboardWidgetState: Equatable {
    /// Newest first. The widget shows at most `ClipboardWidgetController.maximumItems`.
    public var items: [ClipboardWidgetItem]
    /// The row the parent last copied back. It shows "Copied" until the parent clears it.
    public var copiedID: UUID?

    public init(items: [ClipboardWidgetItem] = [], copiedID: UUID? = nil) {
        self.items = items
        self.copiedID = copiedID
    }
}

public enum ClipboardWidgetAction: Equatable, Sendable {
    /// Copy this row's payload back to the pasteboard with its exact type.
    case copy(UUID)
    case remove(UUID)
    /// Open the row's checked http or https link.
    case openLink(UUID)
    /// The header Clear All button.
    case clearAll
}

/// The Clipboard notch widget: the 0.21.35 SwiftUI history list. It never
/// reads the pasteboard and keeps no history of its own.
@MainActor
public final class ClipboardWidgetController: NSViewController, NotchContentProviding {
    public static let maximumItems = 50

    public private(set) var state: ClipboardWidgetState
    let model: ClipboardNotchModel

    public init(state: ClipboardWidgetState, onAction: @escaping @MainActor (ClipboardWidgetAction) -> Void) {
        self.state = state
        model = ClipboardNotchModel(state: state, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = NotchWidgetHost.make(notchContent())
    }

    public func notchContent() -> AnyView { AnyView(ClipboardExpandedView(model: model)) }

    public func update(_ newState: ClipboardWidgetState) {
        guard newState != state else { return }
        state = newState
        model.state = newState
    }
}
