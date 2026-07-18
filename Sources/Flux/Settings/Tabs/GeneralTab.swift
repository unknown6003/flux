import SwiftUI
import AppKit

/// Launch-at-login, both global hotkeys (menu-bar reveal toggle + notch
/// toggle), and the Software Update card — "how Flux starts and how you talk
/// to it from anywhere", gathered in one tab.
struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            generalCard
            hotkeysCard
            SoftwareUpdateCard()
        }
        .padding(20)
    }

    private var generalCard: some View {
        FluxCard(title: "General") {
            ToggleRow(title: "Launch at login",
                      subtitle: "Start Flux automatically when you sign in.",
                      isOn: $settings.launchAtLogin)
        }
    }

    private var hotkeysCard: some View {
        FluxCard(title: "Hotkeys") {
            ToggleRow(title: "Menu bar toggle",
                      subtitle: "Reveal or hide the menu bar from anywhere.",
                      isOn: $settings.enableHotkey)
            if settings.enableHotkey {
                RowDivider()
                HotkeyRow()
            }
            RowDivider()
            NotchHotkeyRow()
        }
    }
}

/// The recordable shortcut row for the menu-bar reveal toggle. Click the
/// field, press a chord, done.
///
/// `RegisterEventHotKey` is first-come-first-served across the whole system, so a
/// chord another app already owns simply fails to register and the hotkey would
/// silently do nothing. `AppDelegate` reports that back as `hotkeyConflict`, and we
/// say so plainly here rather than leaving the user to wonder.
private struct HotkeyRow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowText(title: "Shortcut",
                        subtitle: "Click the field, then press the keys you want.")
                Spacer(minLength: 12)
                HotkeyRecorderView(shortcut: $settings.hotkeyShortcut)
                    .frame(width: 132, height: 26)
                    .fixedSize()
            }
            if settings.hotkeyConflict {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("\(settings.hotkeyShortcut.displayString) is already taken by another app, so it won't reach Flux. Pick a different chord.")
                        .font(.caption).foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if settings.hotkeyShortcut != .default {
                Button("Reset to \(HotkeyShortcut.default.displayString)") {
                    settings.hotkeyShortcut = .default
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accentInkColor)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

/// The notch's own recordable shortcut — a separate chord from the menu-bar
/// toggle, always shown (no master enable toggle for it: an unregistered or
/// invalid chord simply never fires, and the factory default is ⌃⌥⌘N).
private struct NotchHotkeyRow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowText(title: "Notch toggle",
                        subtitle: "Expand or collapse the notch panel from anywhere.")
                Spacer(minLength: 12)
                HotkeyRecorderView(shortcut: $settings.notchHotkey)
                    .frame(width: 132, height: 26)
                    .fixedSize()
            }
            if settings.notchHotkeyConflict {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("\(settings.notchHotkey.displayString) is already taken by another app, so it won't reach Flux. Pick a different chord.")
                        .font(.caption).foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if settings.notchHotkey != .notchDefault {
                Button("Reset to \(HotkeyShortcut.notchDefault.displayString)") {
                    settings.notchHotkey = .notchDefault
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accentInkColor)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
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
        case .installing:
            busyRow("Installing update — Flux will relaunch…")
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
