import AppKit
import SwiftUI

private struct ShellContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<20) { index in
                HStack {
                    Text("Sample app \(index)").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: .constant(0)) {
                        Text("Shown").tag(0)
                        Text("Hidden").tag(1)
                        Text("Always").tag(2)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                }
                .frame(width: 416, height: 24)
            }
        }
        .padding(12)
        .frame(width: 440, height: 600, alignment: .topLeading)
    }
}

@main
struct SwiftUIShell {
    @MainActor static func main() {
        runShell { NSHostingView(rootView: ShellContent()) }
    }
}
