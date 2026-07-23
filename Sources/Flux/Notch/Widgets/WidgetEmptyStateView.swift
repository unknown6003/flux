import SwiftUI

/// The shared monochrome empty-state used by notch widgets (M7 Alcove
/// design language): a dim SF Symbol over a muted caption, centered in the
/// widget's content area. Extracted because Shelf/Timers/Clipboard/Mirror all
/// carried byte-identical copies that would drift the moment the styling was
/// tuned in only one of them.
struct WidgetEmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.white.opacity(0.3))
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
