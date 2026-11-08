import AppKit

@main
struct AppKitShell {
    @MainActor static func main() {
        runShell {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                stack.widthAnchor.constraint(equalToConstant: 416)
            ])
            for index in 0..<20 {
                let label = NSTextField(labelWithString: "Sample app \(index)")
                label.font = .systemFont(ofSize: 13)
                let choice = NSSegmentedControl(labels: ["Shown", "Hidden", "Always"], trackingMode: .selectOne, target: nil, action: nil)
                choice.selectedSegment = 0
                choice.controlSize = .small
                let row = NSStackView(views: [label, NSView(), choice])
                row.orientation = .horizontal
                row.alignment = .centerY
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
            return container
        }
    }
}
