import SwiftUI
import AppKit

/// The sections shown in the Alcove-style sidebar. Selection is intentionally
/// transient: opening Settings starts at the requested section, while the
/// native grouped-window layout stays stable as the user moves around it.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, menuBar, notch, lockScreen, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .notch: return "Notch"
        case .lockScreen: return "Lock Screen"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .notch: return "capsule.portrait"
        case .lockScreen: return "lock"
        case .about: return "info.circle"
        }
    }
}

/// A native-material settings window with Alcove's sidebar/detail hierarchy:
/// compact navigation on the left, a titled detail pane on the right, and
/// translucent grouped cards instead of a branded header plus tab strip.
struct SettingsView: View {
    static let designSize = CGSize(width: 760, height: 620)

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger
    @EnvironmentObject private var nowPlaying: NowPlayingService

    /// Kept for the off-screen renderer and older callers. The live window is
    /// always scrollable because the Notch section is intentionally long.
    var scrolls: Bool
    var initialTab: SettingsTab
    var onTabChange: ((SettingsTab) -> Void)?

    @State private var selectedTab: SettingsTab

    init(scrolls: Bool = true,
         initialTab: SettingsTab = .general,
         onTabChange: ((SettingsTab) -> Void)? = nil) {
        self.scrolls = scrolls
        self.initialTab = initialTab
        self.onTabChange = onTabChange
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)
                .frame(width: 224)

            Rectangle()
                .fill(Theme.settingsDividerColor)
                .frame(width: 1)

            VStack(spacing: 0) {
                SettingsDetailHeader(tab: selectedTab)

                Rectangle()
                    .fill(Theme.settingsDividerColor)
                    .frame(height: 1)

                detailContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .background(SettingsMaterialBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.settingsDividerColor, lineWidth: 1)
        )
        .tint(Theme.accentColor)
        .foregroundStyle(Theme.textPrimaryColor)
        .onChange(of: selectedTab) { _, newValue in
            onTabChange?(newValue)
        }
        // The AppKit window uses a transparent full-size titlebar. Without
        // opting out here, SwiftUI honors the titlebar safe-area inset and
        // leaves an unpainted strip above the rounded settings surface while
        // the traffic lights float on its boundary.
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detailContent: some View {
        if scrolls {
            ScrollView(.vertical) {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general: GeneralTab()
        case .menuBar: MenuBarTab()
        case .notch: NotchTab()
        case .lockScreen: LockScreenTab()
        case .about: AboutTab()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accentWashColor))
                Text("Flux")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)

            sidebarSection("System", tabs: [.general])
            sidebarSection("Flux", tabs: [.menuBar, .notch, .lockScreen])

            Spacer(minLength: 16)

            sidebarSection("About", tabs: [.about])
        }
        .padding(.horizontal, 12)
        .padding(.top, 44)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.settingsSidebarColor)
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondaryColor.opacity(0.8))
                .padding(.leading, 10)
                .padding(.bottom, 3)

            ForEach(tabs) { tab in
                sidebarButton(tab)
            }
        }
        .padding(.bottom, 18)
    }

    private func sidebarButton(_ tab: SettingsTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.textPrimaryColor : Theme.textSecondaryColor)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.settingsSelectionColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsDetailHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondaryColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.settingsSelectionColor)
                )

            Text(tab.title)
                .font(.system(size: 20, weight: .semibold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }
}

/// AppKit's semantic window material gives Alcove its native window-level
/// surface. Light-mode cards use stronger semantic tokens on top so text does
/// not depend on an unpredictable desktop backdrop to remain readable.
private struct SettingsMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .windowBackground
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}
