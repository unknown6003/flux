import AppKit
import FluxCore
import FluxPlatform
import FluxUI

/// byPosition uses wide spacers (macOS 14 to 26). perApplication uses the
/// MenuBarAgent allow list that Flux 0.21.35 shipped on macOS 27.
public enum PositionMenuBarHidingSupport: Sendable {
    case unverified, byPosition, perApplication

    /// The backend for the running OS. macOS 27 needs the allow-list bridge.
    @MainActor public static func current(hider: PerApplicationHider?) -> PositionMenuBarHidingSupport {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return hider?.isAvailable == true ? .perApplication : .unverified
        }
        return .byPosition
    }
}

@MainActor protocol PerApplicationHidingOwner: AnyObject {
    var isAvailable: Bool { get }
    var onResult: (@MainActor (Bool) -> Void)? { get set }
    func apply(policy: VisibilityPolicy, reveal: MenuBarReveal, alwaysHiddenEnabled: Bool)
    func stop()
}

extension PerApplicationHider: PerApplicationHidingOwner {}

@MainActor protocol PositionMenuBarControlOwner: AnyObject {
    var onToggle: (@MainActor (Bool) -> Void)? { get set }
    var onFinishArrange: (@MainActor () -> Void)? { get set }
    var contextMenu: NSMenu? { get set }
    var hiddenBoundary: CGRect? { get }
    var alwaysHiddenBoundary: CGRect? { get }
    func start()
    func stop()
    func configure(capability: MenuBarCapability, reveal: MenuBarReveal,
                   alwaysHiddenEnabled: Bool, style: MenuBarIcon)
    func setArranging(_ arranging: Bool)
}

extension MenuBarControls: PositionMenuBarControlOwner {}

/// What the layout editor needs from the system to move real items.
struct PositionMenuBarArrangeTools {
    var drag: @MainActor (CGPoint, CGPoint) async throws -> Void
    var inputIsQuiet: @MainActor () -> Bool
    var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Flux's own bundle. Its chevron and boundaries are not editor items.
    var ownApplication: ApplicationID?

    static let unavailable = PositionMenuBarArrangeTools(
        drag: { _, _ in throw MenuBarItemDragError.eventsUnavailable }, inputIsQuiet: { true },
        sleep: { _ in }, ownApplication: nil)

    @MainActor static func system() -> PositionMenuBarArrangeTools {
        .init(drag: { try await MenuBarItemDrag.perform(from: $0, to: $1) },
              inputIsQuiet: { MenuBarItemDrag.inputIsQuiet() },
              sleep: { try await Task.sleep(for: .seconds($0)) },
              ownApplication: Bundle.main.bundleIdentifier.flatMap(ApplicationID.init(rawValue:)))
    }
}

private struct PositionMenuBarArrangementContext: Equatable {
    let hidden: CGRect?
    let always: CGRect?
    let screens: [PositionMenuBarScreen]
    let alwaysEnabled: Bool
}

/// Owns only Flux's status items. Saving a group never moves another app's icon
/// or changes another app's allowance. Inventory exists only while demanded.
@MainActor public final class PositionMenuBarService: NSObject, MenuBarService {
    public var onAction: (@MainActor (MenuBarAction) -> Void)?
    public var onChange: (@MainActor () -> Void)?
    public var onOverflow: (@MainActor (Int) -> Void)?
    public private(set) var state: MenuBarPageState

    private static let policyKey = "flux.macOS27IconLayout"
    private static let identityKey = "flux.menuBar.identities.v1"
    private let defaults: UserDefaults
    private let domain: String
    private let preferences: PreferenceStore
    private let support: PositionMenuBarHidingSupport
    private let controls: any PositionMenuBarControlOwner
    private let hider: (any PerApplicationHidingOwner)?
    private var hidingRefused = false
    private var outsideClickMonitor: Any?
    private let readInventory: @MainActor () async -> PositionMenuBarInventory
    private let permissionStatus: @MainActor () -> SystemAccess
    private let requestPreviewPermission: @MainActor () async -> SystemAccess
    private let capturePreviews: @MainActor ([MenuBarLayoutItem]) async throws -> [MenuBarItemID: NSImage]
    private let tools: PositionMenuBarArrangeTools
    private var lastInventory: PositionMenuBarInventory?
    private var itemImages: [MenuBarItemID: NSImage] = [:]
    private var moveTask: Task<Void, Never>?
    private var moveID: UUID?
    private let stopPreviews: @MainActor () -> Void
    private let screens: @MainActor () -> [PositionMenuBarScreen]
    private let quartzFrame: @MainActor (CGRect) -> CGRect
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let observesSystem: Bool
    private let readIdentity: @MainActor (ApplicationID, Data?) async -> MenuBarIdentityEvidence?
    private let confirmIdentity: @MainActor (String) async -> Bool
    private var observations: [PositionMenuBarObservation] = []
    private var scanTask: Task<Void, Never>?
    private var rehideTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?
    private var identityID: UUID?
    private var scanID: UUID?
    private var rehideID: UUID?
    private var previewID: UUID?
    private var policy = VisibilityPolicy()
    private var policyRevision: UInt64 = 0
    private var results: [ApplicationID: MenuBarApplyResult] = [:]
    private var started = false
    private var editorVisible = false
    private var editorShowsAll = false
    private var arranging = false
    private var reveal: MenuBarReveal = .collapsed
    private var policyFailure = false
    private var actionFailure: String?
    private var identityPins = MenuBarIdentityPins()
    private var identities: [ApplicationID: MenuBarIdentityEvidence] = [:]
    private var identitiesValidated = false
    private var identityFailure = false
    private var inventoryVersion: UInt64 = 0
    private var identityVersion: UInt64?
    private var pendingAssignments: [ApplicationID: MenuBarGroup] = [:]

    private var needsInventory: Bool { editorVisible || arranging || support == .byPosition }

    /// Defaults and domain must be the same pair used to create preferences.
    /// The default keeps physical hiding disabled until native proof exists.
    public convenience init(defaults: UserDefaults, domain: String, preferences: PreferenceStore,
                            hidingSupport: PositionMenuBarHidingSupport = .unverified,
                            perApplicationHider: PerApplicationHider? = nil) {
        let inventory = StatusInventory()
        let preview = StatusPreview()
        let identityReader = MenuBarIdentityReader()
        let prompt = MenuBarIdentityPrompt()
        self.init(defaults: defaults, domain: domain, preferences: preferences,
                  hidingSupport: hidingSupport, controls: MenuBarControls(),
                  hider: hidingSupport == .perApplication ? (perApplicationHider ?? PerApplicationHider()) : nil,
                  readInventory: {
                      let snapshot = await inventory.read(RunningApplication.snapshot())
                      return PositionMenuBarInventory(applications: snapshot.applications.map { app in
                          PositionMenuBarApplication(id: app.application.id, name: app.application.name,
                              icon: app.application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                              frames: app.items.map(\.frame), systemItems: app.items.map(\.systemItem))
                      }, accessibilityAllowed: snapshot.accessibilityAllowed, complete: snapshot.complete)
                  }, permissionStatus: { PermissionAccess.status(.accessibility) },
                  requestPreviewPermission: { await PermissionAccess.request(.screenRecording) },
                  capturePreviews: { items in
                      preview.open()
                      let displays = NSScreen.screens.compactMap { screen -> StatusPreviewDisplayBounds? in
                          guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
                          return .init(id: id, frame: CGDisplayBounds(id))
                      }
                      var owners: [UUID: MenuBarItemID] = [:]
                      let regions = items.prefix(128).compactMap { item -> StatusPreviewRegion? in
                          guard let region = StatusInventory.previewRegion(frame: item.frame, displays: displays) else { return nil }
                          owners[region.id] = item.id
                          return region
                      }
                      // The service rereads the menu bar after capture and
                      // drops any image whose item moved meanwhile.
                      let images = try await preview.capture(regions, validating: { _ in true })
                      var result: [MenuBarItemID: NSImage] = [:]
                      for image in images {
                          if let id = owners[image.id] { result[id] = image.image }
                      }
                      return result
                  }, stopPreviews: { preview.close() },
                  screens: {
                      let top = NSScreen.screens.first?.frame.maxY ?? 0
                      return NSScreen.screens.map { screen in
                          PositionMenuBarScreen(frame: CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height),
                              menuBarHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top + 1,
                                  screen.frame.maxY - screen.visibleFrame.maxY))
                      }
                  }, quartzFrame: { frame in
                      CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                             width: frame.width, height: frame.height)
                  }, sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) }, observesSystem: true,
                  readIdentity: { application, saved in
                      let running = NSWorkspace.shared.runningApplications.filter {
                          !$0.isTerminated && $0.bundleIdentifier == application.rawValue
                      }
                      guard running.count == 1, let app = running.first else { return nil }
                      let result = await identityReader.read(processID: app.processIdentifier,
                          application: application, savedRequirement: saved)
                      guard !app.isTerminated else { return nil }
                      return result
                  }, confirmIdentity: { await prompt.confirm(name: $0) }, tools: .system())
    }

    init(defaults: UserDefaults, domain: String, preferences: PreferenceStore,
         hidingSupport: PositionMenuBarHidingSupport, controls: any PositionMenuBarControlOwner,
         hider: (any PerApplicationHidingOwner)? = nil,
         readInventory: @escaping @MainActor () async -> PositionMenuBarInventory,
         permissionStatus: @escaping @MainActor () -> SystemAccess,
         requestPreviewPermission: @escaping @MainActor () async -> SystemAccess,
         capturePreviews: @escaping @MainActor ([MenuBarLayoutItem]) async throws -> [MenuBarItemID: NSImage],
         stopPreviews: @escaping @MainActor () -> Void,
         screens: @escaping @MainActor () -> [PositionMenuBarScreen],
         quartzFrame: @escaping @MainActor (CGRect) -> CGRect,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void, observesSystem: Bool,
         readIdentity: @escaping @MainActor (ApplicationID, Data?) async -> MenuBarIdentityEvidence?,
         confirmIdentity: @escaping @MainActor (String) async -> Bool,
         tools: PositionMenuBarArrangeTools = .unavailable) {
        self.tools = tools
        self.defaults = defaults; self.domain = domain; self.preferences = preferences
        support = hidingSupport; self.controls = controls; self.hider = hider; self.readInventory = readInventory
        self.permissionStatus = permissionStatus; self.requestPreviewPermission = requestPreviewPermission
        self.capturePreviews = capturePreviews; self.stopPreviews = stopPreviews
        self.screens = screens; self.quartzFrame = quartzFrame; self.sleep = sleep
        self.observesSystem = observesSystem
        self.readIdentity = readIdentity; self.confirmIdentity = confirmIdentity
        state = MenuBarPageState(mode: .paused)
        super.init()
        loadPolicy()
        loadIdentities()
        updateOptions()
        updateMode()
    }

    public func start() {
        guard !started else { return }
        started = true
        controls.onToggle = { [weak self] all in
            if all { self?.showAll() } else { self?.toggle() }
        }
        controls.onFinishArrange = { [weak self] in self?.endArrange() }
        hider?.onResult = { [weak self] confirmed in
            guard let self, self.started, self.hidingRefused == confirmed else { return }
            self.hidingRefused = !confirmed
            self.updateMode(); self.changed()
        }
        controls.contextMenu = makeMenu()
        controls.start()
        configure()
        updateObservations()
        if needsInventory { requestScan(arrangeResult: false) }
        onOverflow?(0)
    }

    public func stop() async throws {
        started = false; editorVisible = false; editorShowsAll = false; arranging = false
        identitiesValidated = false
        identityVersion = nil
        observations.removeAll()
        let rehide = rehideTask
        let move = moveTask
        moveID = nil; moveTask?.cancel(); moveTask = nil; state.moveStatus = nil
        cancelScan(); cancelRehide(); discardPreviews()
        cancelIdentityReview()
        controls.setArranging(false)
        controls.configure(capability: .unavailable, reveal: .all,
                           alwaysHiddenEnabled: false, style: state.options.iconStyle)
        hider?.stop(); hider?.onResult = nil; hidingRefused = false
        updateOutsideClickMonitor(reveal: .collapsed)
        controls.stop()
        controls.onToggle = nil; controls.onFinishArrange = nil
        state.isArranging = false
        state.isRefreshing = false
        state.savedLayoutStillApplies = false
        state.mode = .paused
        changed()
        await rehide?.value
        // A drag in flight finishes its few posted events, then stops.
        await move?.value
    }

    public func configure() {
        loadPolicy()
        loadIdentities()
        updateOptions()
        cancelRehide()
        applyControls()
        if started, needsInventory, identityVersion == nil { requestScan(arrangeResult: false) }
        changed()
    }

    public func refresh() {
        guard started, needsInventory else { return }
        actionFailure = nil
        inventoryVersion &+= 1
        identitiesValidated = false
        applyControls()
        requestScan(arrangeResult: false)
    }

    public func setEditorVisible(_ visible: Bool) {
        guard editorVisible != visible else { return }
        editorVisible = visible
        editorShowsAll = visible
        cancelRehide()
        if visible {
            updateObservations()
            requestScan(arrangeResult: false)
        } else {
            arranging = false
            controls.setArranging(false)
            moveID = nil
            moveTask?.cancel(); moveTask = nil
            state.moveStatus = nil
            cancelScan()
            cancelIdentityReview()
            discardPreviews()
            state.isArranging = false
            updateObservations()
            if needsInventory, !identitiesValidated { requestScan(arrangeResult: false) }
        }
        applyControls()
        changed()
    }

    public func toggle() {
        guard started else { return }
        let wasShowingAllForEditor = editorShowsAll
        editorShowsAll = false
        if wasShowingAllForEditor || reveal != .collapsed {
            reveal = .collapsed
            cancelRehide()
        } else {
            reveal = .hidden
            scheduleRehide()
        }
        applyControls()
        changed()
    }

    public func showAll() {
        guard started else { return }
        editorShowsAll = false
        reveal = .all
        scheduleRehide()
        applyControls()
        changed()
    }

    public func assign(_ application: ApplicationID, to group: MenuBarGroup) {
        guard started, editorVisible || arranging else { return }
        guard application.canBeHidden || group == .shown else { return }
        guard let row = state.rows.first(where: { $0.id == application }), !row.isFixed else { return }
        guard !row.needsIdentityReview else {
            results[application] = .failed(code: "identityReviewRequired")
            updateRows(); changed(); return
        }
        if scanTask != nil, !row.needsIdentityReview {
            pendingAssignments[application] = group
            policyRevision &+= 1
            results[application] = .applying
            updateRows(); changed(); return
        }
        guard !identityFailure, identityVersion == inventoryVersion,
              (try? currentIdentities()) == identityPins, identities[application]?.matchesSaved == true else {
            results[application] = .failed(code: "identityUnavailable")
            updateRows(); changed(); return
        }
        do {
            var saved = try currentPolicy()
            try saved.assign(application, to: group)
            savePolicy(saved)
            policyRevision &+= 1
            results[application] = support == .perApplication ? .asked : .notMovedYet
            updateRows()
        } catch { failPolicy() }
        applyControls()
        changed()
    }

    public func beginArrange() {
        guard started else { return }
        cancelScan(); cancelRehide(); discardPreviews()
        actionFailure = nil
        arranging = true
        state.isArranging = true
        controls.setArranging(true)
        updateObservations()
        applyControls()
        requestScan(arrangeResult: false)
        changed()
    }

    public func endArrange() {
        guard started, arranging else { return }
        cancelScan()
        // Keep Flux's labels in place until the fresh geometry read finishes.
        requestScan(arrangeResult: true)
    }

    public func showRealIcons() {
        guard started, editorVisible, previewTask == nil else { return }
        actionFailure = nil
        capturePreviewImages()
    }

    /// Reads each item's real image. Asks for Screen Recording only after the
    /// user's own click. Images whose item moved during capture are dropped.
    private func capturePreviewImages() {
        guard started, editorVisible, previewTask == nil, moveTask == nil else { return }
        let id = UUID()
        previewID = id
        previewTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.previewID == id,
                  self.editorVisible, self.started else { return }
            let access = await self.requestPreviewPermission()
            guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
            var images: [MenuBarItemID: NSImage] = [:]
            if access == .allowed {
                do {
                    let before = self.layoutItems(self.lastInventory)
                    images = try await self.capturePreviews(before)
                    let after = Dictionary(self.layoutItems(await self.readInventory()).map { ($0.id, $0.frame) },
                                           uniquingKeysWith: { first, _ in first })
                    images = images.filter { id, _ in before.first(where: { $0.id == id })?.frame == after[id] }
                } catch {
                    guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
                    self.actionFailure = "previewUnavailable"
                }
            } else { self.actionFailure = "previewPermissionRequired" }
            guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
            self.previewTask = nil; self.previewID = nil
            self.itemImages = images
            for index in self.state.rows.indices {
                self.state.rows[index].preview = images[MenuBarItemID(application: self.state.rows[index].id, index: 0)]
            }
            self.state.showsRealIcons = !images.isEmpty
            if access == .allowed, self.actionFailure == nil, images.isEmpty { self.actionFailure = "previewNoEligibleItems" }
            self.updateTiles()
            self.applyControls()
            self.changed()
        }
    }

    /// Moves one real item, as the layout editor asked. On macOS 27 the group
    /// is saved first, because MenuBarAgent hides whole apps. Then a paced
    /// Cmd-drag puts the item between its new neighbours, checked by a fresh read.
    public func moveItem(_ move: MenuBarItemMove) {
        guard started, editorVisible, scanTask == nil, moveTask == nil else { return }
        let name = tileName(move.item)
        cancelScan(); discardPreviewTask()
        actionFailure = nil
        state.moveStatus = .moving(name: name, attempt: 1)
        let id = UUID()
        moveID = id
        let tools = tools
        moveTask = Task { @MainActor [weak self] in
            guard let self, self.moveID == id else { return }
            var failure: MenuBarMoveFailure?
            do throws(MenuBarMoveFailure) {
                try self.saveGroup(for: move)
                let engine = MenuBarMoveEngine(read: { [weak self] in await self?.readLayout() },
                                               drag: tools.drag, inputIsQuiet: tools.inputIsQuiet, sleep: tools.sleep)
                try await engine.run(move) { [weak self] attempt in
                    guard let self, self.moveID == id else { return }
                    self.state.moveStatus = .moving(name: name, attempt: attempt)
                    self.changed()
                }
            } catch { failure = error }
            guard self.moveID == id, self.started else { return }
            self.state.moveStatus = failure.map { .failed(name: name, $0) } ?? .moved(name: name)
            // Keep the source and anchors revealed through the final geometry
            // read. Saving a hidden group must not conceal the drag source.
            self.requestScan(arrangeResult: self.support == .byPosition && failure == nil, keepImages: true)
            let finalScan = self.scanTask
            await finalScan?.value
            guard self.moveID == id, self.started else { return }
            self.moveTask = nil; self.moveID = nil
            self.applyControls()
            self.changed()
        }
        applyControls()
        changed()
    }

    private func saveGroup(for move: MenuBarItemMove) throws(MenuBarMoveFailure) {
        guard support == .perApplication else { return }
        let application = move.item.application
        let current = policy.group(for: application)
        let shown = current == .alwaysHidden && !state.alwaysHiddenEnabled ? .hidden : current
        guard shown != move.group else { return }
        if move.group == .alwaysHidden, !state.alwaysHiddenEnabled { throw .alwaysHiddenOff }
        guard state.rows.contains(where: { $0.id == application }) else { throw .itemGone }
        assign(application, to: move.group)
        if case .failed(let code)? = results[application] { throw .groupNotSaved(code: code) }
        guard policy.group(for: application) == move.group else { throw .groupNotSaved(code: "notSaved") }
    }

    private func readLayout() async -> MenuBarLayout? {
        let snapshot = await readInventory()
        guard snapshot.accessibilityAllowed else { return nil }
        return MenuBarLayout(items: layoutItems(snapshot), grouping: layoutGrouping())
    }

    /// Every item with a frame, except Flux's own. An app that runs twice is
    /// skipped, because its items cannot be told apart.
    private func layoutItems(_ snapshot: PositionMenuBarInventory?) -> [MenuBarLayoutItem] {
        guard let snapshot else { return [] }
        let counts = Dictionary(grouping: snapshot.applications, by: \.id).mapValues(\.count)
        return snapshot.applications.flatMap { app -> [MenuBarLayoutItem] in
            guard counts[app.id] == 1, app.id != tools.ownApplication else { return [] }
            return app.frames.enumerated().compactMap { index, frame in
                guard let frame, frame.width > 0, frame.height > 0 else { return nil }
                return MenuBarLayoutItem(id: MenuBarItemID(application: app.id, index: index), frame: frame)
            }
        }
    }

    private func layoutGrouping() -> MenuBarGrouping {
        switch support {
        case .perApplication:
            return .perApplication(policy, alwaysHiddenEnabled: state.alwaysHiddenEnabled)
        case .byPosition:
            guard state.mode == .byPosition, let hidden = controls.hiddenBoundary.map(quartzFrame) else { return .none }
            return .byPosition(hidden: hidden,
                               always: state.alwaysHiddenEnabled ? controls.alwaysHiddenBoundary.map(quartzFrame) : nil)
        case .unverified:
            return .none
        }
    }

    private func updateTiles() {
        let layout = MenuBarLayout(items: layoutItems(lastInventory), grouping: layoutGrouping())
        let apps = Dictionary((lastInventory?.applications ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        state.tiles = layout.items.map { item in
            MenuBarLayoutTile(id: item.id, name: tileName(item.id),
                              image: itemImages[item.id] ?? systemImage(item.id) ?? apps[item.id.application]?.icon,
                              group: layout.group(of: item), isMovable: item.isMovable)
        }
    }

    private func systemItem(_ id: MenuBarItemID) -> SystemMenuItem? {
        guard id.application.rawValue == "com.apple.MenuBarAgent",
              let app = lastInventory?.applications.first(where: { $0.id == id.application }),
              app.systemItems.indices.contains(id.index) else { return nil }
        return app.systemItems[id.index]
    }

    private func systemImage(_ id: MenuBarItemID) -> NSImage? {
        let symbol: String
        switch systemItem(id) {
        case .clock: symbol = "clock"
        case .controlCenter: symbol = "switch.2"
        case nil: return nil
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: tileName(id))?
            .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    }

    private func tileName(_ id: MenuBarItemID) -> String {
        guard let app = lastInventory?.applications.first(where: { $0.id == id.application }) else {
            return id.application.rawValue
        }
        switch systemItem(id) {
        case .clock: return String(localized: "Clock")
        case .controlCenter: return String(localized: "Control Center")
        case nil: break
        }
        let count = app.frames.compactMap { $0 }.count
        let name: String
        switch app.id.rawValue {
        case "com.apple.TextInputMenuAgent": name = String(localized: "Input Sources")
        case "com.apple.Passwords.MenuBarExtra": name = String(localized: "Passwords")
        default: name = app.name
        }
        return count > 1 ? "\(name) \(id.index + 1)" : name
    }

    public func checkAccessibility() {
        actionFailure = nil
        applyControls()
        refresh()
        changed()
    }

    public func reviewIdentity(_ application: ApplicationID) {
        guard started, editorVisible, identityTask == nil,
              let row = state.rows.first(where: { $0.id == application }), row.needsIdentityReview,
              let evidence = identities[application],
              let previous = identityPins.requirement(for: application) else { return }
        actionFailure = nil
        let id = UUID()
        identityID = id
        identityTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.identityID == id else { return }
            let accepted = await self.confirmIdentity(row.name)
            guard !Task.isCancelled, self.identityID == id, self.started, self.editorVisible else { return }
            if accepted {
                let fresh = await self.readIdentity(application, previous)
                guard !Task.isCancelled, self.identityID == id, self.started, self.editorVisible else { return }
                do {
                    var pins = try self.currentIdentities()
                    guard pins.requirement(for: application) == previous,
                          let fresh, fresh == evidence else { throw MenuBarIdentityError.invalidRequirement }
                    try pins.trust(application, requirement: fresh.requirement)
                    self.cancelScan()
                    self.saveIdentities(pins)
                    self.results.removeValue(forKey: application)
                } catch { self.actionFailure = "identityChangedDuringReview" }
            }
            self.identityTask = nil; self.identityID = nil
            if accepted, self.actionFailure == nil { self.requestScan(arrangeResult: false) }
            self.applyControls(); self.changed()
        }
    }

    public func setCompactSpacing(_ enabled: Bool) {
        actionFailure = "compactSpacingUnavailable"
        applyControls()
        changed()
    }

    private func updateOptions() {
        state.alwaysHiddenEnabled = preferences.value(for: Preferences.alwaysHiddenEnabled)
        let delay = preferences.value(for: Preferences.autoRehideDelay)
        state.options = MenuBarOptions(autoRehide: preferences.value(for: Preferences.autoRehide),
            autoRehideDelay: delay.isFinite ? min(max(delay, 2), 30) : 8,
            iconStyle: preferences.value(for: Preferences.iconStyle), compactSpacing: nil)
    }

    private func currentPolicy() throws -> VisibilityPolicy {
        try VisibilityPolicy(legacyPropertyList: defaults.persistentDomain(forName: domain)?[Self.policyKey])
    }

    private func currentIdentities() throws -> MenuBarIdentityPins {
        try MenuBarIdentityPins(propertyList: defaults.persistentDomain(forName: domain)?[Self.identityKey])
    }

    private func loadIdentities() {
        do {
            let fresh = try currentIdentities()
            if fresh != identityPins { identitiesValidated = false; identityVersion = nil }
            identityPins = fresh; identityFailure = false
        } catch { identityFailure = true; identitiesValidated = false; identityVersion = nil }
    }

    private func saveIdentities(_ pins: MenuBarIdentityPins) {
        let original = defaults.persistentDomain(forName: domain)?[Self.identityKey] as? [String: Any] ?? [:]
        defaults.set(pins.propertyList(updating: original), forKey: Self.identityKey)
        identityPins = pins; identityFailure = false
    }

    private func loadPolicy() {
        do { policy = try currentPolicy(); policyFailure = false; updateRows() }
        catch { failPolicy() }
    }

    private func savePolicy(_ saved: VisibilityPolicy) {
        let original = defaults.persistentDomain(forName: domain)?[Self.policyKey] as? [String: Any] ?? [:]
        defaults.set(saved.legacyPropertyList(updating: original), forKey: Self.policyKey)
        policy = saved
        policyFailure = false
    }

    private func failPolicy() { policyFailure = true }

    private func updateRows() {
        for index in state.rows.indices {
            state.rows[index].group = policy.group(for: state.rows[index].id)
            state.rows[index].result = results[state.rows[index].id]
            state.rows[index].needsIdentityReview = identities[state.rows[index].id]?.matchesSaved == false
        }
    }

    private func updateMode() {
        if policyFailure { state.mode = .failed(code: "invalidStoredLayout") }
        else if identityFailure { state.mode = .failed(code: "invalidStoredIdentity") }
        else if let actionFailure { state.mode = .failed(code: actionFailure) }
        else if support == .perApplication {
            state.mode = hider?.isAvailable != true ? .failed(code: "hidingUnavailable")
                : hidingRefused ? .failed(code: "hidingRefused") : .perApplication
        }
        else if support == .unverified { state.mode = .paused }
        else if permissionStatus() != .allowed { state.mode = .needsAccessibility }
        else if identities.values.contains(where: { !$0.matchesSaved }) { state.mode = .failed(code: "identityReviewRequired") }
        else if !identitiesValidated { state.mode = .paused }
        else { state.mode = .byPosition }
    }

    /// 0.21.35 collapsed the drawer on a click outside the menu bar. Clicks in
    /// the menu bar keep it open so a revealed icon can be used.
    private func updateOutsideClickMonitor(reveal effective: MenuBarReveal) {
        let wanted = observesSystem && started && effective != .collapsed
        if wanted, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapseAfterOutsideClick() }
            }
        } else if !wanted, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func collapseAfterOutsideClick() {
        guard started, !editorVisible, !arranging, reveal != .collapsed else { return }
        let point = NSEvent.mouseLocation
        let inMenuBar = NSScreen.screens.contains(where: { screen in
            screen.frame.contains(point)
                && point.y >= screen.frame.maxY - max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        })
        guard !inMenuBar else { return }
        reveal = .collapsed
        cancelRehide()
        applyControls()
        changed()
    }

    private func applyControls() {
        updateMode()
        updateTiles()
        updateOutsideClickMonitor(reveal: editorVisible || arranging ? .collapsed : reveal)
        if support == .perApplication {
            let effectiveReveal: MenuBarReveal = editorShowsAll || arranging || moveTask != nil ? .all : reveal
            controls.configure(capability: .perApplication, reveal: effectiveReveal,
                               alwaysHiddenEnabled: state.alwaysHiddenEnabled, style: state.options.iconStyle)
            if started, !policyFailure {
                hider?.apply(policy: policy, reveal: effectiveReveal, alwaysHiddenEnabled: state.alwaysHiddenEnabled)
            } else { hider?.stop() }
            state.savedLayoutStillApplies = false
            return
        }
        let capability: MenuBarCapability = started && support == .byPosition && !policyFailure
            && !identityFailure && identitiesValidated && permissionStatus() == .allowed ? .byPosition : .unavailable
        let effectiveReveal: MenuBarReveal = editorShowsAll || arranging || moveTask != nil ? .all : reveal
        controls.configure(capability: capability, reveal: effectiveReveal,
                           alwaysHiddenEnabled: state.alwaysHiddenEnabled, style: state.options.iconStyle)
        state.savedLayoutStillApplies = false
    }

    private func scheduleRehide() {
        cancelRehide()
        guard !editorVisible, !arranging, state.options.autoRehide else { return }
        let id = UUID()
        rehideID = id
        let delay = state.options.autoRehideDelay
        let sleep = sleep
        rehideTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.rehideID == id,
                  self.started, !self.editorVisible, !self.arranging else { return }
            self.rehideTask = nil; self.rehideID = nil
            self.reveal = .collapsed
            self.applyControls()
            self.changed()
        }
    }

    private func cancelRehide() {
        rehideID = nil; rehideTask?.cancel(); rehideTask = nil
    }

    private func cancelScan() {
        scanID = nil; scanTask?.cancel(); scanTask = nil
        state.isRefreshing = false
        for application in pendingAssignments.keys where results[application] == .applying {
            results.removeValue(forKey: application)
        }
        pendingAssignments.removeAll()
    }

    private func cancelIdentityReview() {
        identityID = nil; identityTask?.cancel(); identityTask = nil
    }

    private func discardPreviewTask() {
        previewID = nil; previewTask?.cancel(); previewTask = nil
        stopPreviews()
    }

    private func discardPreviews() {
        discardPreviewTask()
        state.showsRealIcons = false
        itemImages.removeAll()
        for index in state.rows.indices { state.rows[index].preview = nil }
        updateTiles()
    }

    /// `keepImages` keeps item images across a read that follows a move:
    /// images belong to items, not to places.
    private func requestScan(arrangeResult: Bool, keepImages: Bool = false) {
        guard started, needsInventory, scanTask == nil else { return }
        if keepImages { discardPreviewTask() } else { discardPreviews() }
        let id = UUID()
        scanID = id
        state.isRefreshing = true
        identitiesValidated = false
        applyControls()
        changed()
        scanTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.scanID == id,
                  self.started, self.needsInventory else { return }
            let context = arrangeResult ? self.arrangementContext() : nil
            let revision = self.policyRevision
            let inventoryVersion = self.inventoryVersion
            let initialPolicy = try? self.currentPolicy()
            let initialPins = try? self.currentIdentities()
            let snapshot = await self.readInventory()
            guard !Task.isCancelled, self.scanID == id, self.started, self.needsInventory else { return }
            if inventoryVersion == self.inventoryVersion, snapshot.accessibilityAllowed {
                // App icons need no signing check or screenshot. Keep editing
                // disabled until the rest of this scan has finished.
                self.state.layoutAccessible = true
                self.publish(snapshot)
                self.applyControls()
                self.changed()
            }
            var identities: [ApplicationID: MenuBarIdentityEvidence] = [:]
            if snapshot.accessibilityAllowed, let initialPins {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                let counts = Dictionary(grouping: snapshot.applications, by: \.id).mapValues(\.count)
                for app in snapshot.applications.prefix(128) where !app.id.isManagedBySystem && counts[app.id] == 1 {
                    guard !Task.isCancelled, self.scanID == id, ContinuousClock.now < deadline else { break }
                    identities[app.id] = await self.readIdentity(app.id, initialPins.requirement(for: app.id))
                }
            }
            guard !Task.isCancelled, self.scanID == id, self.started,
                  self.needsInventory else { return }
            self.scanTask = nil; self.scanID = nil
            guard inventoryVersion == self.inventoryVersion else {
                self.requestScan(arrangeResult: arrangeResult, keepImages: keepImages)
                return
            }
            self.state.isRefreshing = false
            self.state.layoutAccessible = snapshot.accessibilityAllowed
            self.identityVersion = nil
            if snapshot.accessibilityAllowed {
                self.identities = identities
                self.identitiesValidated = false
                if let initialPins, (try? self.currentIdentities()) == initialPins {
                    do {
                        var pins = initialPins
                        for (application, evidence) in identities where pins.requirement(for: application) == nil {
                            try pins.trust(application, requirement: evidence.requirement)
                        }
                        if pins != initialPins { self.saveIdentities(pins) }
                        self.identityPins = pins; self.identityFailure = false
                        self.identityVersion = inventoryVersion
                        self.identitiesValidated = snapshot.complete && snapshot.applications.allSatisfy {
                            $0.id.isManagedBySystem || identities[$0.id]?.matchesSaved == true
                        }
                    } catch { self.identityFailure = true }
                } else { self.identityFailure = true }
                self.publish(snapshot)
                let pending = self.pendingAssignments
                self.pendingAssignments.removeAll()
                for (application, group) in pending {
                    self.results.removeValue(forKey: application)
                    self.assign(application, to: group)
                }
                if let context, let initialPolicy, revision == self.policyRevision,
                   !self.identityFailure, self.identityVersion == inventoryVersion,
                   (try? self.currentPolicy()) == initialPolicy, context == self.arrangementContext() {
                    self.saveArrangedPositions(snapshot, context: context)
                } else if arrangeResult {
                    self.loadPolicy()
                }
            } else {
                self.lastInventory = nil
                self.identities.removeAll()
                for application in self.pendingAssignments.keys { self.results[application] = .failed(code: "identityUnavailable") }
                self.pendingAssignments.removeAll()
                self.actionFailure = "accessibilityRequired"
            }
            if arrangeResult {
                self.arranging = false; self.state.isArranging = false
                self.controls.setArranging(false)
                self.updateObservations()
            }
            self.applyControls()
            // A grant used by another feature is not a request for real icon
            // photos. Only Show Real Icons starts a capture.
            self.changed()
        }
    }

    private func publish(_ snapshot: PositionMenuBarInventory) {
        lastInventory = snapshot
        let present = Set(layoutItems(snapshot).map(\.id))
        itemImages = itemImages.filter { present.contains($0.key) }
        var seen: Set<ApplicationID> = []
        state.rows = snapshot.applications.filter { seen.insert($0.id).inserted }.map { app in
            MenuBarAppRow(id: app.id, name: app.name, icon: app.icon,
                iconCount: app.frames.count, group: policy.group(for: app.id),
                needsIdentityReview: identities[app.id]?.matchesSaved == false, result: results[app.id])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func arrangementContext() -> PositionMenuBarArrangementContext {
        PositionMenuBarArrangementContext(hidden: controls.hiddenBoundary.map(quartzFrame),
            always: controls.alwaysHiddenBoundary.map(quartzFrame), screens: screens(),
            alwaysEnabled: state.alwaysHiddenEnabled)
    }

    private func saveArrangedPositions(_ snapshot: PositionMenuBarInventory, context: PositionMenuBarArrangementContext) {
        guard snapshot.complete else { return }
        let assignments = PositionMenuBarGeometry.assignments(applications: snapshot.applications,
            hidden: context.hidden, always: context.always,
            screens: context.screens, alwaysEnabled: context.alwaysEnabled)
        do {
            var saved = try currentPolicy()
            for (application, group) in assignments {
                guard identities[application]?.matchesSaved == true else { continue }
                try saved.assign(application, to: group)
                // A geometry observation does not prove a macOS policy write.
                results.removeValue(forKey: application)
            }
            savePolicy(saved)
            updateRows()
        } catch { failPolicy() }
    }

    private func updateObservations() {
        guard observesSystem, started, needsInventory else {
            observations.removeAll(); return
        }
        guard observations.isEmpty else { return }
        let receive: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observations.append(PositionMenuBarObservation(center: NSWorkspace.shared.notificationCenter,
                                                           name: name, receive: receive))
        }
        observations.append(PositionMenuBarObservation(center: .default,
            name: NSApplication.didChangeScreenParametersNotification, receive: receive))
        // Back from System Settings: a new Accessibility grant shows at once.
        observations.append(PositionMenuBarObservation(center: .default,
            name: NSApplication.didBecomeActiveNotification, receive: receive))
    }

    private func changed() { onChange?() }

    public func contextMenu() -> NSMenu? { makeMenu() }

    /// The chevron's right-click menu. Clicks show and hide icons, so the menu
    /// keeps only what a click cannot do.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Settings…", #selector(menuSettings)), ("Quit Flux", #selector(menuQuit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuSettings() { onAction?(.settings) }
    @objc private func menuQuit() { onAction?(.quit) }
}

private final class PositionMenuBarObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name,
         receive: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: receive)
    }

    deinit { center.removeObserver(token) }
}
