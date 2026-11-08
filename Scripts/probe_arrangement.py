#!/usr/bin/env python3
"""Exercise the production move transaction through its inventory/input/policy seam."""

from pathlib import Path
import tempfile
from probe_update import run

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation

@main struct ArrangementProbe {
    @MainActor static func main() async {
        typealias A = MenuBarArrangement
        let a = A.Handle(id: "calendar|1|1|0", identity: UUID())
        let b = A.Handle(id: "peer|2|1|0", identity: UUID())
        let c = A.Handle(id: "calendar|1|1|1", identity: UUID())
        func item(_ handle: A.Handle, _ x: CGFloat, section: MenuBarSection = .shown,
                  title: String = "Notion Calendar", width: CGFloat = 34) -> A.Item {
            .init(handle: handle, title: title, section: section,
                  frame: CGRect(x: x, y: 4.5, width: width, height: 24))
        }
        var rows = [item(a, 100), item(b, 150), item(c, 250)]
        var revision = 0
        var inputReady = true
        var readable = true
        var reads = 0
        var drags = 0
        var saves = 0
        var movePhysically = true
        var interrupt = false
        var result: Result<Void, A.Failure>?
        var trace: [String] = []
        var appScoped = true
        var saveAllowed = true
        func make() -> A {
            let engine = A(environment: .init(appScoped: appScoped, read: {
                reads += 1
                return readable ? rows : nil
            }, canStart: { inputReady }, inputRevision: { revision }, sectionTarget: { source, _ in
                CGPoint(x: 10, y: source.frame.midY)
            }, drag: { source, _ in
                drags += 1
                if interrupt { revision += 1 }
                if movePhysically {
                    rows = rows.map { row in
                        item(row.handle, row.handle == source.handle ? 220 : row.frame.minX,
                             section: row.section, title: row.title, width: row.frame.width)
                    }
                }
                return true
            }, physicalSection: { _ in .shown }, assign: { source, section, canCommit in
                guard canCommit(), saveAllowed else { return false }
                saves += 1
                let bundle = source.handle.id.split(separator: "|").first
                rows = rows.map { row in
                    item(row.handle, row.frame.minX,
                         section: row.handle.id.split(separator: "|").first == bundle ? section : row.section,
                         title: row.title, width: row.frame.width)
                }
                return true
            }))
            engine.onResult = { result = $0 }
            engine.onTrace = { trace.append($0) }
            return engine
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { print("FAIL: \(label)"); exit(1) }
            print("PASS: \(label)")
        }
        func succeeded() -> Bool { if case .success? = result { return true }; return false }
        func failed(_ expected: A.Failure) -> Bool {
            if case .failure(let actual)? = result { return actual == expected }; return false
        }
        func run(_ engine: A, _ destination: A.Destination,
                 handle: A.Handle? = nil, eligible: @escaping () -> Bool = { true }) async {
            result = nil
            check(engine.submit(.init(item: handle ?? a, destination: destination), eligible: eligible), "request accepted")
            check(engine.isBusy, "busy is published before returning")
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while engine.isBusy, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(!engine.isBusy && result != nil, "request has a bounded terminal result")
        }

        let engine = make()
        await run(engine, .section(.hidden))
        check(succeeded() && drags == 0 && saves == 1, "app section saves with no native drag or divider")
        check(rows.filter { $0.handle.id.hasPrefix("calendar|") }.allSatisfy { $0.section == .hidden }, "all app siblings share visibility")
        await run(engine, .slot(.init(section: .alwaysHidden, before: nil, after: nil)))
        check(succeeded() && drags == 0 && saves == 2, "empty lane is a policy assignment")

        rows = [item(a, 100, title: "Home workout", width: 200), item(b, 150, section: .hidden)]
        let slot = A.Destination.slot(.init(section: .hidden, before: nil, after: b))
        await run(engine, slot)
        check(succeeded() && drags == 1 && saves == 3, "fresh resized item reorders then saves policy")
        await run(engine, slot)
        check(succeeded() && drags == 1, "already satisfied slot does not send native events")

        rows = [item(a, 100), item(b, 150, section: .hidden)]
        movePhysically = false
        let beforeSaves = saves
        await run(engine, slot)
        check(failed(.notMoved("Notion Calendar")) && saves == beforeSaves, "unchanged physical order cannot save or pass")
        movePhysically = true
        interrupt = true
        await run(engine, slot)
        check(failed(.cancelled) && saves == beforeSaves, "new external input cancels policy commit")
        interrupt = false

        rows = [item(a, 100), item(b, 150, section: .hidden)]
        let replacement = A.Handle(id: a.id, identity: UUID())
        let beforeDrags = drags
        await run(engine, .section(.hidden), handle: replacement)
        check(failed(.changed) && drags == beforeDrags, "replacement AX identity is rejected")
        await run(engine, .slot(.init(section: .hidden, before: b, after: b)))
        check(failed(.changed) && drags == beforeDrags, "stale destination adjacency is rejected")
        await run(engine, .section(.hidden), eligible: { false })
        check(failed(.cancelled) && saves == beforeSaves, "closed UI lease sends no events or policy commit")

        readable = false
        let beforeReads = reads
        await run(engine, .section(.hidden))
        check(failed(.unavailable) && reads - beforeReads == 3, "unreadable inventory has three bounded attempts")
        readable = true
        saveAllowed = false
        await run(engine, .section(.hidden))
        check(failed(.notSaved), "policy failure is a terminal error")
        saveAllowed = true

        inputReady = false
        result = nil
        check(engine.submit(.init(item: a, destination: .section(.hidden))), "waiting request accepted")
        check(!engine.submit(.init(item: b, destination: .section(.hidden))), "overlapping request is rejected")
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while engine.isBusy, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(failed(.inputBusy) && !engine.isBusy, "held input cannot leave the module busy forever")
        inputReady = true

        appScoped = false
        let legacy = make()
        await run(legacy, .section(.hidden))
        check(failed(.notMoved("Notion Calendar")), "legacy section change requires physical divider proof")
        print("PASS: arrangement transaction contract")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="flux-arrangement-") as directory:
        path = Path(directory)
        source = path / "Probe.swift"
        source.write_text(FIXTURE)
        binary = path / "probe"
        run(["swiftc", "-swift-version", "5", str(source),
                        str(ROOT / "Sources/Flux/MenuBar/MenuBarArrangement.swift"),
                        str(ROOT / "Sources/Flux/MenuBar/MenuBarSection.swift"),
                        "-o", str(binary)], 90)
        print(run([str(binary)], 30).stdout, end="")


if __name__ == "__main__":
    main()
