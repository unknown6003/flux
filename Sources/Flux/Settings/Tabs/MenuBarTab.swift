import SwiftUI
import AppKit

struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var iconManager: MenuBarIconManager
    @Environment(\.menuBarSnapshotIcons) private var snapshotIcons
    @StateObject private var dragController = MenuBarDragController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if iconManager.isTrusted || snapshotIcons != nil {
                layoutEditor
            } else {
                accessCard
            }
            DisclosureGroup("Menu bar options") {
                VStack(spacing: 16) {
                    behaviorCard
                    appearanceCard
                }
                .padding(.top, 12)
            }
            .font(.body)
        }
        .padding(20)
        .background(MenuBarDragSettingsAnchor(controller: dragController, manager: iconManager)
            .frame(width: 0, height: 0))
        .onAppear { if snapshotIcons == nil { iconManager.beginIconManagement() } }
        .onDisappear {
            dragController.close()
            if snapshotIcons == nil { iconManager.endIconManagement() }
        }
    }

    private var layoutEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Organise icons").font(.headline)
                Spacer()
                Button { dragController.refreshIcons() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(iconManager.isUpdatingIcons)
                Menu {
                    Button("Copy menu bar report") { iconManager.copyMenuBarReport() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Menu bar help")
            }
            Text("Drag an icon to a section, or use its Move menu. Command-drag in the menu bar to change its order.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondaryColor)
            if let message = iconManager.errorMessage ?? dragController.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            ForEach(MenuBarSection.allCases.filter { $0 != .alwaysHidden || settings.showAlwaysHiddenSection }) { section in
                MenuBarIconLane(controller: dragController, manager: iconManager, section: section,
                                icons: (snapshotIcons ?? iconManager.icons).filter { $0.section == section },
                                alwaysHiddenEnabled: settings.showAlwaysHiddenSection)
            }
            Toggle("Always Hidden section", isOn: $settings.showAlwaysHiddenSection)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
            if ControlItem.usesMacOS27Model {
                Text("Apple system icons stay in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondaryColor)
            }
        }
    }

    private var accessCard: some View {
        FluxCard(title: "Organise icons") {
            VStack(alignment: .leading, spacing: 12) {
                RowText(title: "Allow icon management",
                        subtitle: iconManager.canHideWithoutAccess
                            ? "Your saved layout still works. Allow Accessibility to read and move icons."
                            : "Flux needs Accessibility to read and move menu bar icons.")
                Button("Open Accessibility Settings") { iconManager.requestAccess() }
                    .buttonStyle(.fluxProminent)
                Button("Check access again") { iconManager.beginIconManagement() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentInkColor)
                DisclosureGroup("Access is on, but icons are missing") {
                    Text("Quit Flux. Remove its old entry in Accessibility Settings, then add \(Bundle.main.bundleURL.path) and turn it on.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondaryColor)
                }
            }
            .padding(14)
        }
    }

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            ToggleRow(title: "Compact menu-bar spacing",
                      subtitle: "Full effect after your next login.",
                      isOn: $settings.compactMenuBarSpacing)
            RowDivider()
            ToggleRow(title: "Auto re-hide",
                      subtitle: "Hide revealed icons after a delay.",
                      isOn: $settings.autoRehide)
            if settings.autoRehide {
                RowDivider()
                SliderRow(value: $settings.autoRehideDelay, range: 2...30)
            }
        }
    }

    private var appearanceCard: some View {
        FluxCard(title: "Appearance") {
            HStack {
                Text("Menu bar icon")
                Spacer()
                Picker("Menu bar icon", selection: $settings.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in Text(style.displayName).tag(style) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
            }
            .padding(14)
        }
    }
}
