import SwiftUI
import AppKit

/// Menu-bar behavior and the single Flux drawer used to manage real icons.
struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var iconManager: MenuBarIconManager

    var body: some View {
        VStack(spacing: 18) {
            MenuBarPreview()
                .padding(.horizontal, 4)
            drawerCard
            behaviorCard
            appearanceCard
        }
        .padding(20)
        .onAppear { iconManager.beginIconManagement() }
    }

    private var drawerCard: some View {
        FluxCard(title: "Menu Bar Drawer") {
            MenuBarDrawer()
        }
    }

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            ToggleRow(title: "Compact menu-bar spacing",
                      subtitle: "Tightens the gap around every icon so more fit beside the notch. Full effect after your next login.",
                      isOn: $settings.compactMenuBarSpacing)
            RowDivider()
            ToggleRow(title: "Auto re-hide",
                      subtitle: "Hide the drawer again after you reveal it.",
                      isOn: $settings.autoRehide)
            if settings.autoRehide {
                RowDivider()
                SliderRow(value: $settings.autoRehideDelay, range: 2...30)
            }
        }
    }

    private var appearanceCard: some View {
        FluxCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                RowText(title: "Menu bar icon",
                        subtitle: "The glyph Flux shows in the menu bar.")
                Picker("", selection: $settings.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }
}

private struct MenuBarDrawer: View {
    @EnvironmentObject private var iconManager: MenuBarIconManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !iconManager.isTrusted {
                accessRow
            } else if iconManager.icons.isEmpty {
                RowText(title: "No menu-bar icons found",
                        subtitle: "Open a few menu-bar apps, then refresh this drawer.")
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
            } else {
                Text("Choose what stays visible and what goes into the drawer.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                iconSection(.shown)
                RowDivider()
                iconSection(.hidden)
                Button {
                    iconManager.refresh()
                } label: {
                    Label("Refresh icons", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInkColor)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var accessRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowText(title: "Allow icon management",
                    subtitle: "Flux uses Accessibility to read and move menu-bar icons from this drawer.")
            Button("Allow Access") {
                iconManager.requestAccess()
            }
            .buttonStyle(.fluxProminent)
        }
    }

    @ViewBuilder
    private func iconSection(_ section: MenuBarSection) -> some View {
        let items = iconManager.icons.filter { $0.section == section }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.zoneColor(section))
                    .frame(width: 8, height: 8)
                Text(section.displayName)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            if items.isEmpty {
                Text(section == .shown ? "No icons are visible." : "No hidden icons.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondaryColor)
                    .padding(.leading, 15)
            } else {
                ForEach(items) { icon in
                    MenuBarIconRow(icon: icon)
                }
            }
        }
    }
}

private struct MenuBarIconRow: View {
    @EnvironmentObject private var iconManager: MenuBarIconManager
    let icon: MenuBarIconManager.Icon

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon.section.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondaryColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(icon.title)
                    .foregroundStyle(Theme.textPrimaryColor)
                    .lineLimit(1)
                if let source = icon.source {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondaryColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if icon.isMovable {
                Button {
                    iconManager.setSection(icon.section == .shown ? .hidden : .shown, for: icon)
                } label: {
                    Image(systemName: icon.section == .shown ? "arrow.down.to.line" : "arrow.up.to.line")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInkColor)
                .accessibilityLabel(icon.section == .shown ? "Hide \(icon.title)" : "Show \(icon.title)")
            } else {
                Text("System")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondaryColor)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MenuBarPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                zone(count: 3, tint: Theme.zoneColor(.hidden))
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentInkColor)
                zone(count: 2, tint: Theme.zoneColor(.shown))
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surfaceRaisedColor)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.hairlineColor))
            )

            HStack(spacing: 14) {
                legend(.shown)
                legend(.hidden)
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private func zone(count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(tint).frame(width: 11, height: 11)
            }
        }
    }

    private func legend(_ section: MenuBarSection) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.zoneColor(section)).frame(width: 8, height: 8)
            Text(section.displayName)
        }
    }
}
