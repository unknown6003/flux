import SwiftUI

/// Shared row primitives used across every Settings tab — extracted here
/// (rather than duplicated per-tab) when the tab restructure split
/// `SettingsView.swift` into `Tabs/*.swift`.

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairlineColor).frame(height: 1).padding(.leading, 14)
    }
}

struct RowText: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).foregroundStyle(Theme.textPrimaryColor)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondaryColor)
        }
    }
}

struct ToggleRow: View {
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

/// A permission's live status (badge) plus the one action that helps —
/// "Grant Access" while undetermined, "Open System Settings" once denied/
/// restricted, nothing once granted (or on a status this app can't act on).
/// Introduced in M4 for Calendar; written generically over `PermissionKind`
/// so M5 (Accessibility) and M6 (Camera) reuse this exact row rather than
/// each hand-rolling their own — see `PermissionCenter`'s doc comment for why
/// a grant here can't be assumed permanent (ad-hoc signing).
struct PermissionRow: View {
    let kind: PermissionKind
    let title: String
    @ObservedObject var permissions: PermissionCenter

    private var status: PermissionStatus { permissions.statuses[kind] ?? .notDetermined }

    var body: some View {
        HStack(spacing: 12) {
            RowText(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            badge
            actionButton
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }

    private var subtitle: String {
        switch status {
        case .notDetermined: return "Not yet requested."
        case .granted: return "Granted."
        case .denied: return "Denied — re-enable it in System Settings to use this feature."
        case .restricted: return "Restricted by a device policy."
        case .unavailable: return "Unavailable on this Mac."
        }
    }

    private var badge: some View {
        Text(badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(badgeColor.opacity(0.15)))
    }

    private var badgeText: String {
        switch status {
        case .notDetermined: return "Not Determined"
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unavailable: return "Unavailable"
        }
    }

    private var badgeColor: Color {
        switch status {
        case .granted: return Theme.accentColor
        case .denied, .restricted: return Theme.warningColor
        case .notDetermined, .unavailable: return Theme.textSecondaryColor
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notDetermined:
            Button("Grant Access") { permissions.request(kind) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentColor)
        case .denied, .restricted:
            HStack(spacing: 12) {
                // Accessibility never reports `.notDetermined` — `AXIsProcessTrusted()`
                // only ever answers granted-or-not, so the `.notDetermined`
                // branch above is unreachable for this one kind, and
                // `request(.accessibility)`'s `AXIsProcessTrustedWithOptions`
                // prompt (which is what actually registers this app in the
                // TCC list at all) would otherwise never be reachable from
                // this row once denied. Restricted is left alone — a device
                // policy blocking the permission outright isn't something a
                // re-prompt can fix.
                if kind == .accessibility, status == .denied {
                    Button("Grant Access") { permissions.request(kind) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentColor)
                }
                Button("Open System Settings") { permissions.openSystemSettings(kind) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentColor)
            }
        case .granted, .unavailable:
            EmptyView()
        }
    }
}

struct SliderRow: View {
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
