import Foundation
import CoreGraphics

/// One move owns input, verification and policy commit until it has a result.
@MainActor
final class MenuBarArrangement {
    struct Handle: Equatable {
        let id: String
        let identity: UUID?
    }

    struct Item {
        let handle: Handle
        let title: String
        let section: MenuBarSection
        let frame: CGRect
    }

    struct Slot {
        let section: MenuBarSection
        let before: Handle?
        let after: Handle?
    }

    enum Destination {
        case section(MenuBarSection)
        case slot(Slot)

        var section: MenuBarSection {
            switch self {
            case .section(let section): return section
            case .slot(let slot): return slot.section
            }
        }
    }

    struct Request {
        let item: Handle
        let destination: Destination
    }

    struct Environment {
        let appScoped: Bool
        let read: () -> [Item]?
        let canStart: () -> Bool
        let inputRevision: () -> Int
        let sectionTarget: (Item, MenuBarSection) -> CGPoint?
        let drag: (Item, CGPoint) async -> Bool
        let physicalSection: (Item) -> MenuBarSection
        let assign: (Item, MenuBarSection, () -> Bool) -> Bool
    }

    enum Failure: Error, Equatable {
        case changed, cancelled, unavailable, inputBusy, appScope, notMoved(String), notSaved

        var message: String {
            switch self {
            case .changed: return "That icon or destination changed. Try the move again."
            case .cancelled: return "Icon move cancelled because input changed. Try again."
            case .unavailable: return "Flux could not read the menu bar. Try again."
            case .inputBusy: return "Finish the current mouse or menu action, then try again."
            case .appScope: return "This app has other menu bar icons. Choose its section first, then place its icons."
            case .notMoved(let title): return "macOS did not move \(title). Try again."
            case .notSaved: return "Flux could not save the icon's section. Try again."
            }
        }
    }

    private let environment: Environment
    private(set) var isBusy = false
    var onBusy: ((Bool) -> Void)?
    var onResult: ((Result<Void, Failure>) -> Void)?
    var onTrace: ((String) -> Void)?

    init(environment: Environment) { self.environment = environment }

    @discardableResult
    func submit(_ request: Request, eligible: @escaping () -> Bool = { true }) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        onBusy?(true)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.execute(request, eligible: eligible)
            self.isBusy = false
            self.onBusy?(false)
            self.onResult?(result)
        }
        return true
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func snapshot() async -> [Item]? {
        for attempt in 0..<3 {
            if let items = environment.read(), Set(items.map { $0.handle.id }).count == items.count {
                return items
            }
            if attempt < 2 { await pause(0.15) }
        }
        return nil
    }

    private func resolve(_ handle: Handle, in items: [Item]) -> Item? {
        let matches = items.filter { $0.handle == handle }
        guard matches.count == 1, let item = matches.first,
              item.frame.width > 0, item.frame.height > 0,
              item.frame.width.isFinite, item.frame.height.isFinite,
              item.frame.minX.isFinite, item.frame.minY.isFinite else { return nil }
        return item
    }

    private func neighbors(_ item: Item, slot: Slot, in items: [Item]) -> Bool {
        let ordered = items.filter { $0.handle == item.handle || ($0.section == slot.section && $0.handle != item.handle) }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = ordered.firstIndex(where: { $0.handle == item.handle }) else { return false }
        return (index > 0 ? ordered[index - 1].handle : nil) == slot.after
            && (index + 1 < ordered.count ? ordered[index + 1].handle : nil) == slot.before
    }

    private func valid(_ slot: Slot, excluding handle: Handle, in items: [Item]) -> Bool {
        let peers = items.filter { $0.section == slot.section && $0.handle != handle }
            .sorted { $0.frame.minX < $1.frame.minX }
        let index = slot.before.flatMap { next in peers.firstIndex { $0.handle == next } } ?? peers.count
        return (index < peers.count ? peers[index].handle : nil) == slot.before
            && (index > 0 ? peers[index - 1].handle : nil) == slot.after
    }

    private func assigning(_ section: MenuBarSection, to item: Item, in items: [Item]) -> [Item] {
        guard environment.appScoped else { return items }
        let bundle = item.handle.id.split(separator: "|").first
        return items.map { peer in
            Item(handle: peer.handle, title: peer.title,
                 section: peer.handle.id.split(separator: "|").first == bundle ? section : peer.section,
                 frame: peer.frame)
        }
    }

    private func execute(_ request: Request, eligible: @escaping () -> Bool) async -> Result<Void, Failure> {
        let readyBy = ProcessInfo.processInfo.systemUptime + 3
        while !environment.canStart() {
            guard eligible() else { return .failure(.cancelled) }
            guard ProcessInfo.processInfo.systemUptime < readyBy else { return .failure(.inputBusy) }
            await pause(0.05)
        }
        guard eligible() else { return .failure(.cancelled) }
        let revision = environment.inputRevision()
        let canCommit = { eligible() && self.environment.inputRevision() == revision }
        guard let items = await snapshot() else { return .failure(.unavailable) }
        guard canCommit() else { return .failure(.cancelled) }
        guard let item = resolve(request.item, in: items) else { return .failure(.changed) }
        let section = request.destination.section
        var target: CGPoint?
        var slot: Slot?
        switch request.destination {
        case .section:
            if !environment.appScoped { target = environment.sectionTarget(item, section) }
        case .slot(let placement):
            guard valid(placement, excluding: item.handle, in: items) else { return .failure(.changed) }
            let resulting = assigning(section, to: item, in: items)
            if placement.before != nil || placement.after != nil {
                guard valid(placement, excluding: item.handle, in: resulting) else { return .failure(.appScope) }
            }
            slot = placement
            if placement.before == nil && placement.after == nil {
                if !environment.appScoped { target = environment.sectionTarget(item, section) }
            } else if !neighbors(item, slot: placement, in: items) {
                guard let neighborHandle = placement.before ?? placement.after,
                      let neighbor = resolve(neighborHandle, in: items) else { return .failure(.changed) }
                let x = placement.before != nil ? neighbor.frame.midX - 4 : neighbor.frame.midX + 4
                target = CGPoint(x: x, y: item.frame.midY)
            }
        }
        if target == nil && !environment.appScoped {
            guard let slot, neighbors(item, slot: slot, in: items),
                  environment.physicalSection(item) == section else { return .failure(.changed) }
        }
        if let target {
            onTrace?("drag \(item.handle.id) source=\(item.frame) target=\(target) section=\(section.rawValue)")
            guard canCommit() else { return .failure(.cancelled) }
            guard await environment.drag(item, target) else { return .failure(.notMoved(item.title)) }
            await pause(0.45)
            let quietBy = ProcessInfo.processInfo.systemUptime + 3
            while !environment.canStart() {
                guard canCommit() else { return .failure(.cancelled) }
                guard ProcessInfo.processInfo.systemUptime < quietBy else { return .failure(.inputBusy) }
                await pause(0.05)
            }
            guard canCommit() else { return .failure(.cancelled) }
            guard let fresh = await snapshot(), let moved = resolve(item.handle, in: fresh) else {
                return .failure(.unavailable)
            }
            guard canCommit() else { return .failure(.cancelled) }
            let resulting = assigning(section, to: moved, in: fresh)
            let placed = slot.map { neighbors(moved, slot: $0, in: resulting) }
                ?? (environment.physicalSection(moved) == section)
            guard placed, environment.appScoped || environment.physicalSection(moved) == section else {
                onTrace?("unchanged \(item.handle.id) frame=\(moved.frame)")
                return .failure(.notMoved(item.title))
            }
            guard environment.assign(moved, section, canCommit) else { return .failure(.notSaved) }
        } else {
            onTrace?("assign \(item.handle.id) section=\(section.rawValue)")
            guard canCommit() else { return .failure(.cancelled) }
            guard environment.assign(item, section, canCommit) else { return .failure(.notSaved) }
        }
        return .success(())
    }
}
