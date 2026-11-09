import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchDesign.swift,
// Sources/Flux/Support/Theme.swift (notch tokens only) and
// Sources/Flux/Notch/SnapshotEnvironment.swift. Values are unchanged.

/// The notch colours from the 0.21.35 `Theme`.
public enum NotchTheme {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let surfaceRaised = dynamic(light: rgb(0xEFEBE5), dark: rgb(0x272729))
    static let textPrimary = dynamic(light: rgb(0x1A1A1C), dark: rgb(0xF5F4F2))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.14),
                                  dark: NSColor.white.withAlphaComponent(0.10))
    static let notchControlFill = dynamic(light: NSColor.black.withAlphaComponent(0.08),
                                          dark: NSColor.white.withAlphaComponent(0.14))
    static let notchInverseFill = dynamic(light: NSColor.black, dark: NSColor.white)
    static let notchInverseForeground = dynamic(light: NSColor.white, dark: NSColor.black)
    static let notchCollapsed = NSColor.black
    static let notchShadow = dynamic(light: NSColor.black.withAlphaComponent(0.22),
                                     dark: NSColor.black.withAlphaComponent(0.55))
    static let warning = rgb(0xD6524A)

    static var surfaceRaisedColor: Color { Color(nsColor: surfaceRaised) }
    static var textPrimaryColor: Color { Color(nsColor: textPrimary) }
    static var hairlineColor: Color { Color(nsColor: hairline) }
    static var notchControlFillColor: Color { Color(nsColor: notchControlFill) }
    static var notchInverseFillColor: Color { Color(nsColor: notchInverseFill) }
    static var notchInverseForegroundColor: Color { Color(nsColor: notchInverseForeground) }
    static var notchCollapsedColor: Color { Color(nsColor: notchCollapsed) }
    static var notchShadowColor: Color { Color(nsColor: notchShadow) }
    static var warningColor: Color { Color(nsColor: warning) }
}

/// Spacing, type, opacity and radius tokens for the notch surfaces.
public enum NotchDesign {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16

    static let rowSpacing: CGFloat = space2
    static let sectionSpacing: CGFloat = space3
    static let contentPadding: CGFloat = space4

    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 12, weight: .medium)
    static let captionFont = Font.system(size: 11)
    static let microFont = Font.system(size: 9, weight: .semibold)

    static let monoDigitsCaption = Font.system(size: 10, design: .monospaced)
    static let monoDigitsBody = Font.system(size: 12, design: .monospaced)
    static let monoDigitsLarge = Font.system(size: 14, weight: .semibold, design: .monospaced)
    static let monoDigitsSmall = Font.system(size: 11).monospacedDigit()

    static let primaryOpacity: Double = 1.0
    static let secondaryOpacity: Double = 0.55
    static let tertiaryOpacity: Double = 0.45
    static let quaternaryOpacity: Double = 0.3
    static let hairlineOpacity: Double = 0.08

    static let panelRadius: CGFloat = 32
    static let artRadius: CGFloat = 13
    static let tileRadius: CGFloat = 8
    static let rowRadius: CGFloat = 8

    static var physicalNotchFill: Color { NotchTheme.notchCollapsedColor }
    static var panelFill: Color { physicalNotchFill }
    static var primaryColor: Color { NotchTheme.textPrimaryColor }
    static var secondaryColor: Color { NotchTheme.textPrimaryColor.opacity(secondaryOpacity) }
    static var tertiaryColor: Color { NotchTheme.textPrimaryColor.opacity(tertiaryOpacity) }
    static var quaternaryColor: Color { NotchTheme.textPrimaryColor.opacity(quaternaryOpacity) }
    static var hairlineColor: Color { NotchTheme.hairlineColor }
    static var capsuleFill: Color { NotchTheme.notchControlFillColor }
    static var inverseFill: Color { NotchTheme.notchInverseFillColor }
    static var inverseForeground: Color { NotchTheme.notchInverseForegroundColor }

    enum ScrollFadeEdge {
        case bottom
        case trailing
    }

    static let scrollFadeLength: CGFloat = 16
    static let scrollFadeContentInset: CGFloat = 10
    static let paneInsets: CGFloat = space2
}

private struct NotchScrollFadeMask: View {
    let edge: NotchDesign.ScrollFadeEdge

    var body: some View {
        switch edge {
        case .bottom:
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: NotchDesign.scrollFadeLength)
            }
        case .trailing:
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: NotchDesign.scrollFadeLength)
            }
        }
    }
}

private struct NotchScrollFadeModifier: ViewModifier {
    let edge: NotchDesign.ScrollFadeEdge

    func body(content: Content) -> some View {
        content.mask(NotchScrollFadeMask(edge: edge))
    }
}

extension View {
    func notchScrollFade(edge: NotchDesign.ScrollFadeEdge = .bottom) -> some View {
        modifier(NotchScrollFadeModifier(edge: edge))
    }
}

private struct IsSnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IsNarrowPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only in offscreen fixture renders. A display-link timeline does
    /// not tick there, so animated views use a periodic timeline instead.
    public var isSnapshotRender: Bool {
        get { self[IsSnapshotRenderKey.self] }
        set { self[IsSnapshotRenderKey.self] = newValue }
    }

    /// True for the two narrow panes of the Duo view.
    public var isNarrowPane: Bool {
        get { self[IsNarrowPaneKey.self] }
        set { self[IsNarrowPaneKey.self] = newValue }
    }
}

/// A centered glyph and one line, for a widget with nothing to show.
struct WidgetEmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(NotchDesign.quaternaryColor)
            Text(message)
                .font(.caption)
                .foregroundStyle(NotchDesign.secondaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The permission state a gated widget shows, as in 0.21.35.
enum NotchPermissionGate: Equatable {
    case notDetermined
    case denied
    case restricted
    case granted
}

/// Shows an explainer and one capsule button until access is granted.
struct PermissionGatedView<Content: View>: View {
    let status: NotchPermissionGate
    let icon: String
    let notDeterminedMessage: String
    let deniedMessage: String
    let request: () -> Void
    let openSettings: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                explainer(message: notDeterminedMessage, actionTitle: "Grant Access", action: request)
            case .denied:
                explainer(message: deniedMessage, actionTitle: "Open System Settings", action: openSettings)
            case .restricted:
                explainer(message: deniedMessage, actionTitle: nil, action: {})
            case .granted:
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func explainer(message: String, actionTitle: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(NotchDesign.quaternaryColor)
            Text(message)
                .font(.caption)
                .foregroundStyle(NotchDesign.secondaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(NotchCapsuleButtonStyle())
                    .frame(width: 170)
            }
        }
        .padding(.horizontal, NotchDesign.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotchCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NotchDesign.primaryColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(configuration.isPressed ? NotchDesign.primaryColor.opacity(0.20) : NotchDesign.capsuleFill)
            )
            .contentShape(Capsule())
    }
}

/// The 0.21.35 relative age line ("now", "5 min. ago").
enum NotchAge {
    @MainActor private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor static func text(from date: Date, to now: Date = Date()) -> String {
        let interval = max(now.timeIntervalSince(date), 0)
        guard interval >= 60 else { return "now" }
        let flooredPastDate = now.addingTimeInterval(-interval.rounded(.down))
        return formatter.localizedString(for: flooredPastDate, relativeTo: now)
    }
}
