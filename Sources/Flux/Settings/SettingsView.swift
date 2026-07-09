import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Rectangle().fill(Theme.hairlineColor).frame(height: 1)
            VStack(spacing: 18) {
                layoutCard
                generalCard
                behaviorCard
                appearanceCard
                SoftwareUpdateCard()
            }
            .padding(20)
            FooterView()
        }
        .frame(width: 480)
        .background(Theme.groundColor)
        .tint(Theme.accentColor)
        .foregroundStyle(Theme.textPrimaryColor)
    }

    // MARK: Menu bar layout

    /// The one place the user assigns icons to zones. Enters Arrange Mode, which
    /// reveals labeled markers in the live bar so ⌘-drag becomes obvious.
    private var layoutCard: some View {
        FluxCard(title: "Menu Bar Layout") {
            ArrangeRows()
        }
    }

    // MARK: General

    private var generalCard: some View {
        FluxCard(title: "General") {
            ToggleRow(title: "Launch at login",
                      subtitle: "Start Flux automatically when you sign in.",
                      isOn: $settings.launchAtLogin)
            RowDivider()
            ToggleRow(title: "Auto-hide on launch",
                      subtitle: "Tuck items away as soon as Flux starts.",
                      isOn: $settings.autoHideOnLaunch)
            RowDivider()
            ToggleRow(title: "Always-Hidden zone",
                      subtitle: "A second zone revealed only with ⌥ (option).",
                      isOn: $settings.showAlwaysHiddenSection)
        }
    }

    // MARK: Behavior

    private var behaviorCard: some View {
        FluxCard(title: "Behavior") {
            ToggleRow(title: "Auto re-hide",
                      subtitle: "Collapse again a moment after revealing.",
                      isOn: $settings.autoRehide)
            if settings.autoRehide {
                RowDivider()
                SliderRow(value: $settings.autoRehideDelay, range: 2...30)
            }
            RowDivider()
            ToggleRow(title: "Toggle hotkey",
                      subtitle: "Reveal or hide with ⌥⌘B from anywhere.",
                      isOn: $settings.enableHotkey)
        }
    }

    // MARK: Appearance

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

// MARK: - Software Update

/// The OTA surface: a status line that reflects `UpdateChecker.state`, the
/// primary action for that state (check / download / re-open the installer), and
/// an auto-check toggle. When an update is found it's presented in a prominent
/// amber banner so it doesn't get lost among the settings.
private struct SoftwareUpdateCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var updater: UpdateChecker

    var body: some View {
        FluxCard(title: "Software Update") {
            VStack(alignment: .leading, spacing: 12) {
                content
                Rectangle().fill(Theme.hairlineColor).frame(height: 1)
                HStack(spacing: 12) {
                    RowText(title: "Automatically check for updates",
                            subtitle: "Quietly look for a newer Flux on GitHub.")
                    Spacer(minLength: 12)
                    Toggle("", isOn: $settings.automaticUpdateChecks)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accentColor)
                }
                Text(footerText)
                    .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle:
            checkButton("Check for Updates")
        case .checking:
            busyRow("Checking for updates…")
        case .upToDate:
            VStack(alignment: .leading, spacing: 10) {
                statusLine("checkmark.circle.fill", Theme.accentColor,
                           "Flux \(AppInfo.version) is up to date.")
                checkButton("Check Again")
            }
        case .available(let release):
            availableBanner(release)
        case .downloading:
            busyRow("Downloading update…")
        case .readyToInstall(let url):
            VStack(alignment: .leading, spacing: 10) {
                statusLine("checkmark.circle.fill", Theme.accentColor,
                           "Downloaded — drag Flux to Applications in the window that opened.")
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open Installer Again", systemImage: "externaldrive")
                }
                .buttonStyle(.fluxProminent)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                statusLine("exclamationmark.triangle.fill", .orange, message)
                checkButton("Try Again")
            }
        }
    }

    // MARK: Pieces

    private func availableBanner(_ release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accentInkColor)
                Text("Update available — \(release.name)")
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimaryColor)
                Spacer(minLength: 0)
            }
            if !release.notes.isEmpty {
                Text(release.notes)
                    .font(.caption).foregroundStyle(Theme.textSecondaryColor)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { updater.downloadAndInstall(release) } label: {
                Label("Download & Install", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.fluxProminent)
            Button { NSWorkspace.shared.open(release.pageURL) } label: {
                Text("View release on GitHub")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.accentInkColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentWashColor)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accentColor.opacity(0.35)))
        )
    }

    private func checkButton(_ title: String) -> some View {
        Button { updater.checkForUpdates(userInitiated: true) } label: {
            Label(title, systemImage: "arrow.clockwise")
        }
        .buttonStyle(.fluxProminent)
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.body).foregroundStyle(Theme.textPrimaryColor)
            Spacer(minLength: 0)
        }
    }

    private func statusLine(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(Theme.textPrimaryColor)
            Spacer(minLength: 0)
        }
    }

    private var footerText: String {
        guard let date = updater.lastChecked else { return "Flux \(AppInfo.version)" }
        return "Flux \(AppInfo.version) · Last checked \(date.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Row scaffolding

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairlineColor).frame(height: 1).padding(.leading, 14)
    }
}

private struct RowText: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).foregroundStyle(Theme.textPrimaryColor)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondaryColor)
        }
    }
}

/// The interactive contents of the "Menu Bar Layout" card. Toggles Arrange Mode
/// and, while it's active, spells out exactly how the ⌘-drag zoning works so the
/// live markers in the bar aren't a mystery.
private struct ArrangeRows: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if arranger.isArranging {
                arrangingContent
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .animation(.easeInOut(duration: 0.15), value: arranger.isArranging)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowText(title: "Organize your menu bar",
                    subtitle: "Choose which icons stay Shown, tuck into Hidden, or go Always-Hidden.")
            Button {
                arranger.setArranging(true)
            } label: {
                Label("Arrange Menu Bar…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.fluxProminent)
        }
    }

    private var arrangingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(Theme.accentColor).frame(width: 8, height: 8)
                Text("Arranging your menu bar").font(.body.weight(.semibold))
            }
            // The coloured markers are live in your menu bar right now — mirror them
            // here so it's obvious what each one means and which way to drag.
            CmdDragCallout()
            Text("Drag each icon into a zone — right to left in your bar:")
                .font(.callout).foregroundStyle(Theme.textSecondaryColor)
            VStack(alignment: .leading, spacing: 8) {
                ArrangeZoneLegendRow(zone: nil, desc: "Stays visible, next to the clock")
                ArrangeZoneLegendRow(zone: .hidden, desc: "Tucked behind the chevron")
                if settings.showAlwaysHiddenSection {
                    ArrangeZoneLegendRow(zone: .alwaysHidden, desc: "Revealed only with ⌥ option")
                }
            }
            Text("Click Done — or the ✓ that replaced the Flux icon — to apply.")
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            Button {
                arranger.setArranging(false)
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.fluxProminent)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accentColor)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

private struct SliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 12) {
            Text("Delay").foregroundStyle(Theme.textPrimaryColor)
            Slider(value: $value, in: range, step: 1).tint(Theme.accentColor)
            Text("\(Int(value))s")
                .foregroundStyle(Theme.textSecondaryColor)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 16) {
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
            MenuBarPreview(showAlwaysHidden: settings.showAlwaysHiddenSection)
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

// MARK: - Live menu-bar preview

/// A faux menu bar that teaches the zone model at a glance and reflects the
/// Always-Hidden toggle live. Each zone's dots carry its marker colour so the
/// preview, the live markers, and the legend all read as one system.
private struct MenuBarPreview: View {
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if showAlwaysHidden {
                    zone(count: 2, tint: Theme.zoneColor(.alwaysHidden))
                    glyph("chevron.left.2")
                }
                zone(count: 3, tint: Theme.zoneColor(.hidden))
                glyph("chevron.left", accent: true)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.hairlineColor)
                    )
            )

            HStack(spacing: 14) {
                legend(section: .shown, label: "Shown")
                legend(section: .hidden, label: "Hidden")
                if showAlwaysHidden {
                    legend(section: .alwaysHidden, label: "Always-Hidden")
                }
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

    private func glyph(_ name: String, accent: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? Theme.accentInkColor : Theme.textSecondaryColor)
    }

    private func legend(section: MenuBarSection, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.zoneColor(section)).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    var body: some View {
        HStack {
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.caption)
                .foregroundStyle(Theme.textSecondaryColor)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Flux").foregroundStyle(Theme.textSecondaryColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.groundColor)
    }
}
