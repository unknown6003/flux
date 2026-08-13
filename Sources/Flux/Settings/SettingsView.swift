import SwiftUI
import AppKit

/// Which top-level Settings section is showing. Not persisted — reopening
/// Settings always starts on `initialTab` (General by default).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, menuBar, notch, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .notch: return "Notch"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .notch: return "capsule.portrait"
        case .about: return "info.circle"
        }
    }
}

/// The settings window uses one predictable canvas for every section. The
/// sidebar/detail split follows the native preferences pattern used by Alcove:
/// navigation never moves, while the selected page owns its own scroll view.
enum SettingsLayout {
    static let contentWidth: CGFloat = 860
    static let contentHeight: CGFloat = 620
    static let sidebarWidth: CGFloat = 194
}

/// The Settings window's root view: a fixed sidebar, a detail header, and the
/// selected tab's scrollable content. Keeping navigation outside the detail
/// scroll view prevents a tall tab from moving the controls used to switch
/// tabs and keeps every section in the same window frame.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger
    @EnvironmentObject private var nowPlaying: NowPlayingService

    /// When false the tab's content renders in a plain, self-sizing column for
    /// specialized off-screen callers. The production window uses the default
    /// `true` value, so a tall tab scrolls inside the stable detail pane.
    var scrolls: Bool
    /// Which tab opens first. `--render-settings`/`--snapshot` pass it directly
    /// so CI/dev tooling can capture any single tab headlessly.
    var initialTab: SettingsTab
    /// Fired whenever the user switches tabs so the window controller can keep
    /// track of the selected page without changing the window frame.
    var onTabChange: ((SettingsTab) -> Void)?

    @State private var selectedTab: SettingsTab

    init(scrolls: Bool = true, initialTab: SettingsTab = .general, onTabChange: ((SettingsTab) -> Void)? = nil) {
        self.scrolls = scrolls
        self.initialTab = initialTab
        self.onTabChange = onTabChange
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)
            Rectangle()
                .fill(Theme.hairlineColor)
                .frame(width: 1)
            VStack(spacing: 0) {
                SettingsDetailHeader(tab: selectedTab)
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 1)
                if scrolls {
                    ScrollView(showsIndicators: false) { tabContent }
                } else {
                    tabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsLayout.contentWidth,
               height: scrolls ? SettingsLayout.contentHeight : nil,
               alignment: .top)
        .background(Theme.groundColor)
        .tint(Theme.accentColor)
        .foregroundStyle(Theme.textPrimaryColor)
        .onChange(of: selectedTab) { _, newValue in onTabChange?(newValue) }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general: GeneralTab()
        case .menuBar: MenuBarTab()
        case .notch: NotchTab()
        case .about: AboutTab()
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FLUX")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondaryColor)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 10)

            SidebarSection(title: "Settings") {
                sidebarButton(.general)
                sidebarButton(.menuBar)
                sidebarButton(.notch)
            }

            SidebarSection(title: "App") {
                sidebarButton(.about)
            }

            Spacer(minLength: 0)
        }
        .frame(width: SettingsLayout.sidebarWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceRaisedColor.opacity(0.42))
    }

    private func sidebarButton(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.textPrimaryColor : Theme.textSecondaryColor)
            .frame(height: 38, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.surfaceColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .padding(.horizontal, 10)
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondaryColor.opacity(0.8))
                .padding(.horizontal, 18)
                .padding(.bottom, 3)
            content
        }
        .padding(.bottom, 18)
    }
}

private struct SettingsDetailHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimaryColor)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.surfaceRaisedColor)
                )
            Text(tab.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimaryColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
