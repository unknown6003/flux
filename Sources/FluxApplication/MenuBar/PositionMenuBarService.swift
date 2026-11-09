import AppKit
import FluxCore
import FluxPlatform
import FluxUI

/// Select byPosition only after the spacer backend passes native acceptance.
public enum PositionMenuBarHidingSupport: Sendable {
    case unverified, byPosition
}

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
    private let defaults: UserDefaults
    private let domain: String
    private let preferences: PreferenceStore
    private let support: PositionMenuBarHidingSupport
    private let controls: any PositionMenuBarControlOwner
    private let readInventory: @MainActor () async -> PositionMenuBarInventory
    private let permissionStatus: @MainActor () -> SystemAccess
    private let requestPreviewPermission: @MainActor () async -> SystemAccess
    private let screens: @MainActor () -> [PositionMenuBarScreen]
    private let quartzFrame: @MainActor (CGRect) -> CGRect
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let observesSystem: Bool
    private var observations: [PositionMenuBarObservation] = []
    private var scanTask: Task<Void, Never>?
    private var rehideTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var scanID: UUID?
    private var rehideID: UUID?
    private var previewID: UUID?
    private var policy = VisibilityPolicy()
    private var results: [ApplicationID: MenuBarApplyResult] = [:]
    private var started = false
    private var editorVisible = false
    private var arranging = false
    private var reveal: MenuBarReveal = .collapsed
    private var policyFailure = false
    private var actionFailure: String?

    /// Defaults and domain must be the same pair used to create preferences.
    /// The default keeps physical hiding disabled until native proof exists.
    public convenience init(defaults: UserDefaults, domain: String, preferences: PreferenceStore,
                            hidingSupport: PositionMenuBarHidingSupport = .unverified) {
        let inventory = StatusInventory()
        self.init(defaults: defaults, domain: domain, preferences: preferences,
                  hidingSupport: hidingSupport, controls: MenuBarControls(),
                  readInventory: {
                      let snapshot = await inventory.read(RunningApplication.snapshot())
                      return PositionMenuBarInventory(applications: snapshot.applications.map { app in
                          PositionMenuBarApplication(id: app.application.id, name: app.application.name,
                              icon: app.application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                              frames: app.items.map(\.frame))
                      }, accessibilityAllowed: snapshot.accessibilityAllowed, complete: snapshot.complete)
                  }, permissionStatus: { PermissionAccess.status(.accessibility) },
                  requestPreviewPermission: { await PermissionAccess.request(.screenRecording) },
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
                  }, sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) }, observesSystem: true)
    }

    init(defaults: UserDefaults, domain: String, preferences: PreferenceStore,
         hidingSupport: PositionMenuBarHidingSupport, controls: any PositionMenuBarControlOwner,
         readInventory: @escaping @MainActor () async -> PositionMenuBarInventory,
         permissionStatus: @escaping @MainActor () -> SystemAccess,
         requestPreviewPermission: @escaping @MainActor () async -> SystemAccess,
         screens: @escaping @MainActor () -> [PositionMenuBarScreen],
         quartzFrame: @escaping @MainActor (CGRect) -> CGRect,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void, observesSystem: Bool) {
        self.defaults = defaults; self.domain = domain; self.preferences = preferences
        support = hidingSupport; self.controls = controls; self.readInventory = readInventory
        self.permissionStatus = permissionStatus; self.requestPreviewPermission = requestPreviewPermission
        self.screens = screens; self.quartzFrame = quartzFrame; self.sleep = sleep
        self.observesSystem = observesSystem
        state = MenuBarPageState(mode: .paused)
        super.init()
        loadPolicy()
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
        controls.contextMenu = makeMenu()
        controls.start()
        configure()
        onOverflow?(0)
    }

    public func stop() async throws {
        started = false; editorVisible = false; arranging = false
        observations.removeAll()
        let scan = scanTask; let rehide = rehideTask; let preview = previewTask
        cancelScan(); cancelRehide(); discardPreviews()
        controls.setArranging(false)
        controls.configure(capability: .unavailable, reveal: .all,
                           alwaysHiddenEnabled: false, style: state.options.iconStyle)
        controls.stop()
        controls.onToggle = nil; controls.onFinishArrange = nil
        state.isArranging = false
        state.isRefreshing = false
        state.savedLayoutStillApplies = false
        state.mode = .paused
        changed()
        await scan?.value
        await rehide?.value
        await preview?.value
    }

    public func configure() {
        loadPolicy()
        updateOptions()
        cancelRehide()
        applyControls()
        changed()
    }

    public func refresh() {
        guard started, editorVisible || arranging else { return }
        actionFailure = nil
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
            discardPreviews()
            state.isArranging = false
            updateObservations()
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
        guard !application.isManagedBySystem else { return }
        guard let row = state.rows.first(where: { $0.id == application }), !row.isFixed else { return }
        guard !row.needsIdentityReview else {
            results[application] = .failed(code: "identityReviewRequired")
            updateRows(); changed(); return
        }
        do {
            var saved = try currentPolicy()
            try saved.assign(application, to: group)
            savePolicy(saved)
            results[application] = .notMovedYet
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
        let id = UUID()
        previewID = id
        previewTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.previewID == id,
                  self.editorVisible, self.started else { return }
            let access = await self.requestPreviewPermission()
            guard !Task.isCancelled, self.previewID == id, self.editorVisible, self.started else { return }
            self.previewTask = nil; self.previewID = nil
            // AX frames alone cannot authorize capture of another app's pixels.
            self.actionFailure = access == .allowed ? "previewEligibilityUnavailable" : "previewPermissionRequired"
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
        guard state.rows.contains(where: { $0.id == application }) else { return }
        results[application] = .failed(code: "identityReviewUnavailable")
        updateRows()
        changed()
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
        }
    }

    private func updateMode() {
        if policyFailure { state.mode = .failed(code: "invalidStoredLayout") }
        else if let actionFailure { state.mode = .failed(code: actionFailure) }
        else if support == .unverified { state.mode = .paused }
        else if permissionStatus() != .allowed { state.mode = .needsAccessibility }
        else { state.mode = .byPosition }
    }

    private func applyControls() {
        updateMode()
        let capability: MenuBarCapability = started && support == .byPosition && !policyFailure ? .byPosition : .unavailable
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
    }

    private func discardPreviews() {
        previewID = nil; previewTask?.cancel(); previewTask = nil
        state.showsRealIcons = false
        for index in state.rows.indices { state.rows[index].preview = nil }
    }

    private func requestScan(arrangeResult: Bool) {
        guard started, editorVisible || arranging, scanTask == nil else { return }
        let id = UUID()
        scanID = id
        state.isRefreshing = true
        changed()
        scanTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.scanID == id,
                  self.started, self.editorVisible || self.arranging else { return }
            let context = arrangeResult ? self.arrangementContext() : nil
            let snapshot = await self.readInventory()
            guard !Task.isCancelled, self.scanID == id, self.started,
                  self.editorVisible || self.arranging else { return }
            self.scanTask = nil; self.scanID = nil
            self.state.isRefreshing = false
            if snapshot.accessibilityAllowed {
                self.publish(snapshot)
                if let context, context == self.arrangementContext() {
                    self.saveArrangedPositions(snapshot, context: context)
                }
            } else { self.actionFailure = "accessibilityRequired" }
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
                iconCount: app.frames.count, group: policy.group(for: app.id), result: results[app.id])
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
                try saved.assign(application, to: group)
                // A geometry observation does not prove a macOS policy write.
                results.removeValue(forKey: application)
            }
            savePolicy(saved)
            updateRows()
        } catch { failPolicy() }
    }

    private func updateObservations() {
        guard observesSystem, started, editorVisible || arranging else {
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
