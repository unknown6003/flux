import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var arranger: MenuBarArranger

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider().opacity(0.35)
            VStack(spacing: 18) {
                layoutCard
                generalCard
                behaviorCard
                appearanceCard
            }
            .padding(20)
            FooterView()
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Menu bar layout

    /// The one place the user assigns icons to zones. Enters Arrange Mode, which
    /// reveals labeled markers in the live bar so ⌘-drag becomes obvious.
    private var layoutCard: some View {
        SettingsCard(title: "Menu Bar Layout") {
            ArrangeRows()
        }
    }

    // MARK: General

    private var generalCard: some View {
        SettingsCard(title: "General") {
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
        SettingsCard(title: "Behavior") {
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
        SettingsCard(title: "Appearance") {
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

// MARK: - Card scaffolding

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 14)
    }
}

private struct RowText: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var arrangingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                Text("Arranging your menu bar").font(.body.weight(.semibold))
            }
            // The coloured markers are live in your menu bar right now — mirror them
            // here so it's obvious what each one means and how to use them.
            (Text("Hold ") + Text("⌘").fontWeight(.bold)
             + Text(" and drag your menu-bar icons across the markers:"))
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                chipRow(.hidden, "drop an icon to its left to hide it")
                if settings.showAlwaysHiddenSection {
                    chipRow(.alwaysHidden, "to its left → Always-Hidden (reveal with ⌥)")
                }
                chipRow(.shown, "anything right of Hidden stays Shown", arrow: false)
            }
            Text("Click Done — or the ✓ that replaced the Flux icon — to apply.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                arranger.setArranging(false)
            } label: {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func chipRow(_ section: MenuBarSection, _ text: String, arrow: Bool = true) -> some View {
        HStack(spacing: 8) {
            ArrangeMarkerChip(section: section, showArrow: arrow)
            Text(text).font(.callout).foregroundStyle(.secondary)
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
                .tint(.accentColor)
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
            Text("Delay")
            Slider(value: $value, in: range, step: 1).tint(.accentColor)
            Text("\(Int(value))s")
                .foregroundStyle(.secondary)
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
                    Text(AppInfo.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

/// The app mark: a soft gradient tile with a chevron — the minimal identity.
private struct FluxMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(colors: [Color(red: 0.40, green: 0.49, blue: 0.98),
                                        Color(red: 0.55, green: 0.36, blue: 0.96)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 46, height: 46)
            .overlay(
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

// MARK: - Live menu-bar preview

/// A faux menu bar that teaches the zone model at a glance and reflects the
/// Always-Hidden toggle live.
private struct MenuBarPreview: View {
    let showAlwaysHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if showAlwaysHidden {
                    zone(count: 2, tint: .secondary.opacity(0.45))
                    glyph("chevron.left.2")
                }
                zone(count: 3, tint: .secondary.opacity(0.7))
                glyph("chevron.left", accent: true)
                zone(count: 2, tint: .primary.opacity(0.8))
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
            )

            HStack(spacing: 14) {
                legend(color: .primary.opacity(0.8), label: "Shown")
                legend(color: .secondary.opacity(0.7), label: "Hidden")
                if showAlwaysHidden {
                    legend(color: .secondary.opacity(0.45), label: "Always-Hidden")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
            .foregroundStyle(accent ? Color.accentColor : .secondary)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
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
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Flux")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
