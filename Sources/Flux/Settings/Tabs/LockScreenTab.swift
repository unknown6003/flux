import SwiftUI

/// Lock-screen controls live in their own sidebar section now, matching the
/// feature's importance and keeping the Notch page focused on notch-only
/// behaviour.
struct LockScreenTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 14) {
            FluxCard(title: "Lock Screen") {
                ToggleRow(
                    title: "Show Flux on the lock screen",
                    subtitle: "Keep the notch, live activity, and media controls visible while your Mac is locked.",
                    isOn: $settings.notchLockScreenExperimentEnabled)

                if settings.notchLockScreenExperimentEnabled {
                    RowDivider()
                    ToggleRow(
                        title: "Now Playing",
                        subtitle: "Show artwork, title, artist, and previous/play/next controls when something is playing.",
                        isOn: $settings.notchLockScreenNowPlayingEnabled)
                    RowDivider()
                    ToggleRow(
                        title: "Live activity",
                        subtitle: "Show the current battery, Bluetooth, calendar, or timer activity as a pill.",
                        isOn: $settings.notchLockScreenActivitiesEnabled)
                    RowDivider()
                    ToggleRow(
                        title: "Unlock sound",
                        subtitle: "Play a short confirmation sound when the lock screen disappears.",
                        isOn: $settings.notchLockScreenUnlockSoundEnabled)
                }
            }

            FluxCard(title: "System") {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentInkColor)
                        .frame(width: 22, height: 22)

                    RowText(
                        title: "Designed for the lock screen",
                        subtitle: "Flux places its overlay in macOS’s lock-screen window space and reconciles the state continuously, so a missed wake or lock notification does not leave it behind.")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
        }
        .padding(24)
    }
}
