import AppKit
import SwiftUI

/// Flux's design system.
///
/// A small, *semantic* token set built on the brand palette — **Matte Black**
/// (`#0A0A0A`), **Obsidian** (`#1C1C1E`), and **Industrial Amber** (`#FFB000`) —
/// applied with a 60 / 30 / 10 balance: matte-black grounds carry ~60% of the
/// surface, obsidian panels ~30%, and amber is reserved for the ~10% that should
/// actually draw the eye (the chevron, primary actions, focus).
///
/// Every token is appearance-aware — the same name resolves to a dark or light
/// value automatically — so the menu-bar markers (drawn in AppKit) and the
/// Settings UI (SwiftUI) share one source of truth and never drift apart.
enum Theme {

    // MARK: - Palette primitives

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// Resolve to a light- or dark-appearance value at draw time.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Semantic tokens (NSColor)

    /// 60% — the dominant matte-black (dark) / warm off-white (light) canvas.
    static let ground = dynamic(light: rgb(0xF6F4F1), dark: rgb(0x0A0A0A))
    /// 30% — obsidian panels and cards raised off the ground.
    static let surface = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1C1C1E))
    /// A slightly lifted surface for insets / controls on a card.
    static let surfaceRaised = dynamic(light: rgb(0xEFEBE5), dark: rgb(0x272729))

    static let textPrimary = dynamic(light: rgb(0x1A1A1C), dark: rgb(0xF5F4F2))
    static let textSecondary = dynamic(light: rgb(0x6C675F), dark: rgb(0x9B968E))

    /// Hairline separators / card borders — a whisper of the opposite tone.
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.09),
                                  dark: NSColor.white.withAlphaComponent(0.10))

    /// 10% — Industrial Amber, the single accent. Used for fills, tints, the
    /// live chevron. Nudged marginally deeper in light mode so it stays vivid on
    /// white without glowing out.
    static let accent = dynamic(light: rgb(0xF0A400), dark: rgb(0xFFB000))
    /// Amber that stays legible *as text* — darkened on light grounds where a
    /// bright amber would wash out; the full brand amber on dark.
    static let accentInk = dynamic(light: rgb(0x9A6300), dark: rgb(0xFFB000))
    /// A faint amber wash for highlighting the accented zone / active surfaces.
    static let accentWash = dynamic(light: rgb(0xF0A400).withAlphaComponent(0.12),
                                    dark: rgb(0xFFB000).withAlphaComponent(0.15))

    /// A desaturated red reserved for genuinely urgent wings (a low-battery
    /// live activity) — deliberately outside the amber family so a warning
    /// reads as distinct from "just another accented highlight." Fixed
    /// across appearances, same reasoning as `zone(_:)`.
    static let warning = rgb(0xD6524A)

    // MARK: - Zone marker colours

    /// A warm, amber-anchored ramp — gold → burnt orange → rust — that reads as
    /// one family with the accent yet keeps the three zones instantly
    /// distinguishable. Fixed across appearances (a marker means the same thing
    /// on every menu bar) and dark enough to carry white label text.
    static func zone(_ section: MenuBarSection) -> NSColor {
        switch section {
        case .shown:        return rgb(0xC98A18)   // amber gold — the visible zone
        case .hidden:       return rgb(0xC15A22)   // burnt orange — the drawer
        case .alwaysHidden: return rgb(0x8E4130)   // deep rust — tucked furthest away
        }
    }

    // MARK: - SwiftUI mirrors

    static var groundColor: Color { Color(nsColor: ground) }
    static var surfaceColor: Color { Color(nsColor: surface) }
    static var surfaceRaisedColor: Color { Color(nsColor: surfaceRaised) }
    static var textPrimaryColor: Color { Color(nsColor: textPrimary) }
    static var textSecondaryColor: Color { Color(nsColor: textSecondary) }
    static var hairlineColor: Color { Color(nsColor: hairline) }
    static var accentColor: Color { Color(nsColor: accent) }
    static var accentInkColor: Color { Color(nsColor: accentInk) }
    static var accentWashColor: Color { Color(nsColor: accentWash) }
    static var warningColor: Color { Color(nsColor: warning) }
    static func zoneColor(_ section: MenuBarSection) -> Color { Color(nsColor: zone(section)) }

    /// The app mark fill — the true brand amber with a faint top sheen, matching
    /// the app icon. Near-flat: enough depth to read as a mark, no orange fade.
    static var markGradient: LinearGradient {
        LinearGradient(colors: [Color(nsColor: rgb(0xFFC752)), Color(nsColor: rgb(0xFFB000))],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Reusable component styles

/// The one primary action style — an amber, full-width, filled button. Replaces
/// scattered `.borderedProminent` + tint calls so every call site is identical.
struct FluxProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentColor)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

extension ButtonStyle where Self == FluxProminentButtonStyle {
    static var fluxProminent: FluxProminentButtonStyle { .init() }
}

/// A titled settings card: an uppercased label above an obsidian panel with a
/// hairline border. The single container primitive for the Settings surface.
struct FluxCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondaryColor)
                .tracking(0.9)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surfaceColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairlineColor)
                )
        }
    }
}
