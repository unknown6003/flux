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
    private let readInventory: @MainActor () async -> PositionMenuBarInventory
    private let permissionStatus: @MainActor () -> SystemAccess
    private let requestPreviewPermission: @MainActor () async -> SystemAccess
    private let capturePreviews: @MainActor () async throws -> [ApplicationID: NSImage]
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
                              frames: app.items.map(\.frame))
                      }, accessibilityAllowed: snapshot.accessibilityAllowed, complete: snapshot.complete)
                  }, permissionStatus: { PermissionAccess.status(.accessibility) },
                  requestPreviewPermission: { await PermissionAccess.request(.screenRecording) },
                  capturePreviews: {
                      preview.open()
                      let displays = NSScreen.screens.compactMap { screen -> StatusPreviewDisplayBounds? in
                          guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
                          return .init(id: id, frame: CGDisplayBounds(id))
                      }
                      let candidates = await inventory.previewCandidates(RunningApplication.snapshot(), displays: displays)
                      try Task.checkCancellation()
                      let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.region.id, $0) })
                      let images = try await preview.capture(candidates.map(\.region), validating: { region in
                          guard let candidate = byID[region.id],
                                NSRunningApplication(processIdentifier: candidate.processID)?.bundleIdentifier == candidate.application.rawValue else { return false }
                          return await inventory.validatePreview(candidate)
                      })
                      let apps = Dictionary(uniqueKeysWithValues: candidates.map { ($0.region.id, $0.application) })
                      var result: [ApplicationID: NSImage] = [:]
                      for image in images {
                          if let app = apps[image.id] { result[app] = image.image }
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
                  }, confirmIdentity: { await prompt.confirm(name: $0) })
    }

    init(defaults: UserDefaults, domain: String, preferences: PreferenceStore,
         hidingSupport: PositionMenuBarHidingSupport, controls: any PositionMenuBarControlOwner,
         hider: (any PerApplicationHidingOwner)? = nil,
         readInventory: @escaping @MainActor () async -> PositionMenuBarInventory,
         permissionStatus: @escaping @MainActor () -> SystemAccess,
         requestPreviewPermission: @escaping @MainActor () async -> SystemAccess,
         capturePreviews: @escaping @MainActor () async throws -> [ApplicationID: NSImage],
         stopPreviews: @escaping @MainActor () -> Void,
         screens: @escaping @MainActor () -> [PositionMenuBarScreen],
         quartzFrame: @escaping @MainActor (CGRect) -> CGRect,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void, observesSystem: Bool,
         readIdentity: @escaping @MainActor (ApplicationID, Data?) async -> MenuBarIdentityEvidence?,
         confirmIdentity: @escaping @MainActor (String) async -> Bool) {
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
        started = false; editorVisible = false; arranging = false
        identitiesValidated = false
        identityVersion = nil
        observations.removeAll()
        let rehide = rehideTask
        cancelScan(); cancelRehide(); discardPreviews()
        cancelIdentityReview()
        controls.setArranging(false)
        controls.configure(capability: .unavailable, reveal: .all,
                           alwaysHiddenEnabled: false, style: state.options.iconStyle)
        hider?.stop(); hider?.onResult = nil; hidingRefused = false
        controls.stop()
        controls.onToggle = nil; controls.onFinishArrange = nil
        state.isArranging = false
        state.isRefreshing = false
        state.savedLayoutStillApplies = false
        state.mode = .paused
        changed()
        await rehide?.value
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
        cancelRehide()
        if visible {
            updateObservations()
            requestScan(arrangeResult: false)
        } else {
            arranging = false
            controls.setArranging(false)
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
        if reveal == .collapsed { reveal = .hidden; scheduleRehide() }
        else { reveal = .collapsed; cancelRehide() }
        applyControls()
        changed()
    }

    public func showAll() {
        guard started else { return }
        reveal = .all
        scheduleRehide()
        applyControls()
        changed()
    }

    public func assign(_ application: ApplicationID, to group: MenuBarGroup) {
        guard started, editorVisible || arranging else { return }
        guard !application.isManagedBySystem else { return }
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
        let id = UUID()
        previewID = id
        previewTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.previewID == id,
                  self.editorVisible, self.started else { return }
            let access = await self.requestPreviewPermission()
            guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
            var images: [ApplicationID: NSImage] = [:]
            if access == .allowed {
                do { images = try await self.capturePreviews() }
                catch {
                    guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
                    self.actionFailure = "previewUnavailable"
                }
            } else { self.actionFailure = "previewPermissionRequired" }
            guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
            self.previewTask = nil; self.previewID = nil
            for index in self.state.rows.indices { self.state.rows[index].preview = images[self.state.rows[index].id] }
            self.state.showsRealIcons = self.state.rows.contains { $0.preview != nil }
            if access == .allowed, self.actionFailure == nil, !self.state.showsRealIcons { self.actionFailure = "previewNoEligibleItems" }
            self.applyControls()
            self.changed()
        }
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

    private func applyControls() {
        updateMode()
        if support == .perApplication {
            let effectiveReveal: MenuBarReveal = editorVisible || arranging ? .all : reveal
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
        let effectiveReveal: MenuBarReveal = editorVisible || arranging ? .all : reveal
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

    private func discardPreviews() {
        previewID = nil; previewTask?.cancel(); previewTask = nil
        stopPreviews()
        state.showsRealIcons = false
        for index in state.rows.indices { state.rows[index].preview = nil }
    }

    private func requestScan(arrangeResult: Bool) {
        guard started, needsInventory, scanTask == nil else { return }
        discardPreviews()
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
                self.requestScan(arrangeResult: arrangeResult)
                return
            }
            self.state.isRefreshing = false
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
            self.changed()
        }
    }

    private func publish(_ snapshot: PositionMenuBarInventory) {
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
    }

    private func changed() { onChange?() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, represented: Any? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; item.representedObject = represented; menu.addItem(item)
        }
        add("Show or Hide Icons", #selector(menuToggle))
        add("Reveal All Icons", #selector(menuShowAll))
        add("Organize Menu Bar…", #selector(menuOrganize))
        menu.addItem(.separator())
        add("Open Notch", #selector(menuNotch))
        for minutes in [5, 15, 25] {
            add("Start \(minutes) Minute Timer", #selector(menuTimer(_:)), represented: minutes)
        }
        add("Cancel Timers", #selector(menuCancelTimers))
        menu.addItem(.separator())
        add("Settings…", #selector(menuSettings))
        add("Quit Flux", #selector(menuQuit))
        return menu
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuShowAll() { showAll() }
    @objc private func menuOrganize() { onAction?(.organize) }
    @objc private func menuNotch() { onAction?(.openNotch) }
    @objc private func menuTimer(_ sender: NSMenuItem) {
        if let minutes = sender.representedObject as? Int { onAction?(.startTimer(minutes: minutes)) }
    }
    @objc private func menuCancelTimers() { onAction?(.cancelTimers) }
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
