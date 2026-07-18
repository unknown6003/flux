import SwiftUI
import AppKit

/// Which top-level Settings section is showing. Not persisted — reopening
/// Settings always starts on `initialTab` (General by default), matching the
/// plan's "custom, not TabView chrome" tab bar.
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

/// The Settings window's root view: a slim header, a custom segmented tab
/// bar, and the selected tab's scrollable content.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger
    @EnvironmentObject private var nowPlaying: NowPlayingService

    /// When false the tab's content renders in a plain, self-sizing column — used
    /// off-screen to measure the window's natural height. On screen (`true`, the
    /// default) it lives in a `ScrollView`, so a tall tab scrolls instead of
    /// overflowing the bottom of a short display.
    var scrolls: Bool
    /// Which tab opens first. `SettingsWindowController` also uses this to
    /// re-measure the *current* tab's natural height when the user switches
    /// tabs; `--render-settings`/`--snapshot` pass it directly so CI/dev
    /// tooling can capture any single tab headlessly.
    var initialTab: SettingsTab
    /// Fired whenever the user switches tabs, so `SettingsWindowController`
    /// can re-fit the window to the new tab's natural height.
    var onTabChange: ((SettingsTab) -> Void)?

    @State private var selectedTab: SettingsTab

    init(scrolls: Bool = true, initialTab: SettingsTab = .general, onTabChange: ((SettingsTab) -> Void)? = nil) {
        self.scrolls = scrolls
        self.initialTab = initialTab
        self.onTabChange = onTabChange
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            TabBar(selection: $selectedTab)
            Rectangle().fill(Theme.hairlineColor).frame(height: 1)
            if scrolls {
                ScrollView { tabContent }
            } else {
                tabContent
            }
        }
        .frame(width: 480)
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

// MARK: - Tab bar

/// A custom, Theme-styled segmented control — deliberately not `TabView`
/// (whose chrome doesn't match Flux's card-and-hairline visual language).
private struct TabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceRaisedColor)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: 11, weight: .medium))
                Text(tab.title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.black.opacity(0.85) : Theme.textSecondaryColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Header

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            FluxMark()
            VStack(alignment: .leading, spacing: 2) {
                Text("Flux")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text(AppInfo.tagline)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

/// The app mark: an Industrial Amber tile with a matte-black chevron — the
/// minimal identity, accent-forward as a logo should be.
private struct FluxMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.markGradient)
            .frame(width: 46, height: 46)
            .overlay(
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
            )
            .shadow(color: Theme.accentColor.opacity(0.35), radius: 6, y: 2)
    }
}
