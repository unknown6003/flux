import SwiftUI
import AppKit

/// Menu-bar behavior and the drawer used to manage real icons.
struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var iconManager: MenuBarIconManager

    var body: some View {
        VStack(spacing: 18) {
            MenuBarPreview(showAlwaysHidden: settings.showAlwaysHiddenSection)
                .padding(.horizontal, 4)
            drawerCard
            behaviorCard
            appearanceCard
        }
        .padding(20)
        .onAppear { iconManager.beginIconManagement() }
        .onDisappear { iconManager.endIconManagement() }
    }

    private var drawerCard: some View {
        FluxCard(title: "Menu Bar Drawer") {
            MenuBarDrawer()
        }
    }

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            ToggleRow(title: "Always-Hidden section",
                      subtitle: "Option-click the Flux chevron to reveal it.",
                      isOn: $settings.showAlwaysHiddenSection)
            RowDivider()
            ToggleRow(title: "Compact menu-bar spacing",
                      subtitle: "Tightens the gap around every icon. Full effect after your next login.",
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
                        subtitle: "The glyph Flux shows in your menu bar.")
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
            } else {
                RowText(title: "Manage icons here",
                        subtitle: "Use Move to… and the arrows below. You do not need to drag icons in the tiny menu bar.")
                if let errorMessage = iconManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(MenuBarSection.allCases) { section in
                    iconSection(section)
                    if section != .alwaysHidden { RowDivider() }
                }
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
                    subtitle: "Flux uses Accessibility to read and move menu-bar icons from this drawer. Flux will not ask again after access is granted.")
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
            Text(section.subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecondaryColor)
                .padding(.leading, 15)
            if items.isEmpty {
                Text(emptyText(for: section))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondaryColor)
                    .padding(.leading, 15)
                    .padding(.top, 2)
            } else {
                ForEach(items) { icon in
                    MenuBarIconRow(icon: icon)
                }
            }
        }
    }

    private func emptyText(for section: MenuBarSection) -> String {
        switch section {
        case .shown: return "No icons are visible."
        case .hidden: return "No hidden icons."
        case .alwaysHidden: return "No always-hidden icons."
        }
    }
}

private struct MenuBarIconRow: View {
    @EnvironmentObject private var iconManager: MenuBarIconManager
    let icon: MenuBarIconManager.Icon

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon.section.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondaryColor)
                .frame(width: 17)
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
            Spacer(minLength: 2)
            if icon.isMovable {
                Button {
                    iconManager.move(icon, toward: .towardDrawer)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!iconManager.canMove(icon, toward: .towardDrawer))
                .accessibilityLabel("Move \(icon.title) toward the drawer")

                Button {
                    iconManager.move(icon, toward: .towardClock)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!iconManager.canMove(icon, toward: .towardClock))
                .accessibilityLabel("Move \(icon.title) toward the clock")

                Menu {
                    ForEach(MenuBarSection.allCases) { section in
                        Button {
                            iconManager.move(icon, to: section)
                        } label: {
                            Label(section.displayName, systemImage: section.symbolName)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Move \(icon.title) to another section")
            }
        }
        .foregroundStyle(Theme.accentInkColor)
        .padding(.vertical, 5)
    }
}

private struct MenuBarPreview: View {
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if showAlwaysHidden {
                    zone(count: 2, tint: Theme.zoneColor(.alwaysHidden))
                    boundary
                }
                zone(count: 3, tint: Theme.zoneColor(.hidden))
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentInkColor)
                zone(count: 2, tint: Theme.zoneColor(.shown))
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                if showAlwaysHidden { legend(.alwaysHidden) }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private var boundary: some View {
        Rectangle()
            .fill(Theme.zoneColor(.alwaysHidden))
            .frame(width: 1, height: 17)
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
