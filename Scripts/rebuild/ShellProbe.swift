import AppKit
import Darwin
import QuartzCore

@MainActor
final class ShellProbe: NSObject, NSApplicationDelegate {
    private let factory: @MainActor () -> NSView
    private let window = NSPanel(
        contentRect: NSRect(x: 300, y: 200, width: 440, height: 600),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )

    init(factory: @escaping @MainActor () -> NSView) { self.factory = factory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.isReleasedWhenClosed = false
        window.contentView = nil
        sample("closed") {
            self.show()
            self.sample("shown") {
                let start = ContinuousClock.now
                for _ in 0..<20 {
                    autoreleasepool {
                        self.window.orderOut(nil)
                        self.window.contentView = nil
                        self.show()
                        self.window.orderOut(nil)
                        self.window.contentView = nil
                    }
                }
                let elapsed = start.duration(to: .now).components
                self.emit(["phase": "cycles", "count": 20, "nanoseconds": Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9])
                self.sample("closedAfterCycles") { NSApp.terminate(nil) }
            }
        }
    }

    private func show() {
        window.contentView = factory()
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private func sample(_ phase: String, completion: @escaping @MainActor () -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        let before = cpu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.finishSample(phase, started: started, before: before)
            completion()
        }
    }

    private func finishSample(_ phase: String, started: TimeInterval, before: Double) {
        let interval = ProcessInfo.processInfo.systemUptime - started
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { exit(2) }
        emit([
            "phase": phase, "intervalSeconds": interval,
            "cpuPercentOfOneCore": (cpu() - before) / interval * 100,
            "physicalFootprintBytes": info.phys_footprint,
            "residentBytes": info.resident_size
        ])
    }

    private func cpu() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(3) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

@MainActor
func runShell(factory: @escaping @MainActor () -> NSView) {
    let app = NSApplication.shared
    let delegate = ShellProbe(factory: factory)
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
