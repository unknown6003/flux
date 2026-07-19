import SwiftUI

/// Shared explainer UI for any notch widget gated behind a TCC permission.
///
/// `CalendarWidget`'s expanded panel used to hand-roll its own
/// notDetermined/denied/restricted/unavailable explainer (icon + message +
/// the one action that helps) inline — a code review extracted it here once
/// M6's Mirror widget (camera access) needed the exact same three-state
/// layout, differing only in per-kind copy/icon. `CalendarWidget` is the
/// first consumer; `MirrorWidget` reuses this exact wrapper rather than
/// re-implementing the same explainer a second time.
///
/// `PermissionRow` (`Settings/SettingsRows.swift`) is a deliberately separate,
/// denser one-line layout for a completely different surface (a Settings list
/// row, not a notch panel) — it stays as its own type rather than being
/// folded into this one.
struct PermissionGatedView<Content: View>: View {
    let kind: PermissionKind
    @ObservedObject var permissions: PermissionCenter

    /// SF Symbol shown above the explainer message — the widget's own icon
    /// (e.g. "calendar"), not anything permission-specific.
    let icon: String
    /// Shown with a "Grant Access" button while the permission has never
    /// been decided.
    let notDeterminedMessage: String
    /// Shown with an "Open System Settings" button for every status that
    /// isn't `.notDetermined`/`.granted` (denied, restricted, or
    /// unavailable) — there's no system prompt left to trigger again once a
    /// grant has been explicitly denied, so System Settings is the only
    /// remaining recovery path in every one of those cases.
    let deniedMessage: String
    @ViewBuilder let content: () -> Content

    private var status: PermissionStatus { permissions.statuses[kind] ?? .notDetermined }

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                explainer(message: notDeterminedMessage, actionTitle: "Grant Access",
                          action: { permissions.request(kind) })
            case .denied, .restricted, .unavailable:
                explainer(message: deniedMessage, actionTitle: "Open System Settings",
                          action: { permissions.openSystemSettings(kind) })
            case .granted:
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func explainer(message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(Theme.accentColor.opacity(0.6))
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.fluxProminent)
                .frame(width: 170)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
