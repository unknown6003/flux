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
