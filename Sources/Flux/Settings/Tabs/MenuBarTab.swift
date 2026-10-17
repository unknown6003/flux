import SwiftUI
import AppKit

struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var iconManager: MenuBarIconManager
    @Environment(\.menuBarSnapshotIcons) private var snapshotIcons
    @StateObject private var dragController = MenuBarDragController()
    @StateObject private var images = MenuBarIconImages()

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
        .onAppear {
            dragController.onWindowClose = { [weak images] in images?.close() }
            if snapshotIcons == nil {
                iconManager.beginIconManagement()
                images.open(iconManager.icons)
            }
        }
        .onChange(of: iconManager.icons) { icons in if snapshotIcons == nil { images.refresh(icons) } }
        .onDisappear {
            images.close()
            dragController.close()
            if snapshotIcons == nil { iconManager.endIconManagement() }
        }
    }

    private var layoutEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Organise icons").font(.headline)
                Spacer()
                Button {
                    dragController.refreshIcons()
                    images.refresh(iconManager.icons, force: true)
                } label: {
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
            Text("Drag between icons to place them. Click an icon for move options, or use Tab and Space.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondaryColor)
            if snapshotIcons == nil, !images.hasAccess {
                Button("Show actual menu bar icons…") { images.requestAccess(iconManager.icons) }
                    .font(.caption)
                    .help("Allow Screen Recording to show menu bar images. App icons work without it.")
            }
            Group {
                if iconManager.isUpdatingIcons {
                    Label("Checking icon positions…", systemImage: "arrow.triangle.2.circlepath")
                } else if let message = iconManager.errorMessage ?? dragController.message {
                    Text(message).foregroundStyle(.orange)
                } else {
                    Text(images.message ?? " ")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondaryColor)
            .lineLimit(2)
            .frame(height: 28, alignment: .leading)
            ForEach(MenuBarSection.allCases.filter {
                $0 != .alwaysHidden || settings.showAlwaysHiddenSection
                    || (snapshotIcons ?? iconManager.icons).contains { $0.section == .alwaysHidden }
            }) { section in
                MenuBarIconLane(controller: dragController, manager: iconManager, images: images, section: section,
                                icons: (snapshotIcons ?? iconManager.icons).filter { $0.section == section },
                                alwaysHiddenEnabled: settings.showAlwaysHiddenSection)
            }
            Toggle("Always Hidden section", isOn: $settings.showAlwaysHiddenSection)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
            if ControlItem.usesMacOS27Model {
                Text("Moving one icon moves all icons from that app. Apple system icons stay in the menu bar.")
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
