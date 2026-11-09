import AppKit
import FluxCore
import FluxPlatform
import FluxUI
import QuickLookThumbnailing

/// Makes the five notch widget controllers and binds them to the real feeds,
/// repositories and files.
///
/// Ownership: the app owns the preferences, `ShelfFiles`, `ClipboardRepository`,
/// `PasteboardChannel` and the effects object, and keeps this coordinator.
/// `FeatureRuntime` owns every live feed through the handle a `start…Feed`
/// call returns. The coordinator holds the visible controller and the feeds
/// weakly, plus small last-known states. `effects` is unowned, so the effects
/// object may own the coordinator. It must outlive it.
///
/// Order the app must keep:
/// 1. `onWillSwitch`: apply `FeatureDemand` with the new visible widget, then
///    the panel calls `makeWidget`.
/// 2. `onWillDismiss`: apply `FeatureDemand` with no visible widget, then call
///    `dismiss()`. Camera stops before the Mirror view goes.
///
/// Making a controller reads no hardware, permission prompt or pasteboard.
@MainActor
public final class WidgetCoordinator {
    /// Rows the clipboard widget gets.
    public static let maximumClipboardRows = 50
    /// Files one drop may copy. The rest are refused with `.shelfDropLimited`.
    public static let maximumDropFiles = 20
    /// Captures waiting for the repository. More are dropped with a fixed code.
    public static let maximumPendingCaptures = 4

    private let preferences: PreferenceStore
    private let shelf: ShelfFiles
    private let clipboard: ClipboardRepository
    private let pasteboard: PasteboardChannel
    private let mediaScript: URL
    private let mediaFramework: URL
    private unowned let effects: any WidgetEffects

    // Feeds. FeatureRuntime keeps the lease. Each lease clears its own slot on stop.
    private weak var mediaLease: ServiceLease<MediaFeed>?
    private weak var calendarLease: ServiceLease<CalendarFeed>?
    private weak var clipboardLease: ServiceLease<ClipboardFeed>?
    private weak var cameraLease: ServiceLease<CameraFeed>?

    public var onContentChange: (@MainActor (Widget) -> Void)?

    // The primary widget and its optional Calendar companion.
    private var visible: Widget?
    private var calendarIsCompanion = false
    private var widgetVisit: UUID?
    private var calendarVisit: UUID?
    private var mediaCommands: MediaCommandAuthorization?
    private var writeAuthorization: ClipboardWriteAuthorization?
    private weak var nowPlayingView: NowPlayingWidgetController?
    private weak var calendarView: CalendarWidgetController?
    private weak var mirrorView: MirrorWidgetController?
    private weak var clipboardView: ClipboardWidgetController?
    private weak var shelfView: FileShelfWidgetController?
    private var cameraPreview: CameraPreviewView?

    // Visible work. Cancelled on hide.
    private var elapsedTask: Task<Void, Never>?
    private var clipboardSubscription: Task<Void, Never>?
    private var shelfLoad: Task<Void, Never>?
    private var shelfMaintenance: Task<Void, Never>?
    private var shelfExpiry: Double?

    // Last-known light states.
    private var media: MediaFeedState?
    private var lastSnapshot: MediaSnapshot?
    private var artworkID: UUID?
    private var artwork: NSImage?
    private lazy var artworkPipeline = ArtworkPipeline { [weak self] id, decoded in
        guard let self, self.visible == .nowPlaying, self.artworkID == id else { return }
        self.artwork = decoded.map { NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height)) }
        self.nowPlayingView?.update(self.nowPlayingState())
    }
    private var sourceNames: [ApplicationID: String] = [:]
    private var agenda: AgendaReadResult?
    private var camera: CameraState?
    private var clipboardRecords: [ClipboardRecord] = []
    private var clipboardThumbnails: [UUID: NSImage] = [:]
    private var copiedID: UUID?
    private var pendingCaptures = 0
    private var clipboardPrepare: Task<Void, Never>?
    private var shelfFiles: [ShelvedFile] = []
    private var shelfURLs: [UUID: URL] = [:]
    /// QuickLook thumbnails, made only while File Shelf is open, as in 0.21.35.
    private var shelfThumbnails: [UUID: NSImage] = [:]
    private var thumbnailRequests: Set<UUID> = []
    private var shelfFailed = false
    private var shelfLoaded = false
    private var copyJob: ShelfCopyBatch?
    private var copyingRows: [FileShelfWidgetItem] = []

    public init(preferences: PreferenceStore, shelf: ShelfFiles, clipboard: ClipboardRepository,
                pasteboard: PasteboardChannel, mediaScript: URL, mediaFramework: URL,
                effects: any WidgetEffects) {
        self.preferences = preferences
        self.shelf = shelf
        self.clipboard = clipboard
        self.pasteboard = pasteboard
        self.mediaScript = mediaScript
        self.mediaFramework = mediaFramework
        self.effects = effects
    }

    deinit { writeAuthorization?.revoke(); mediaCommands?.revoke(); shelfMaintenance?.cancel() }

    // MARK: Panel

    private func action<Value: Sendable>(_ visit: UUID,
        perform: @escaping @MainActor @Sendable (WidgetCoordinator, Value) -> Void
    ) -> @MainActor @Sendable (Value) -> Void {
        { [weak self] value in
            guard let self, self.widgetVisit == visit || self.calendarVisit == visit else { return }
            perform(self, value)
        }
    }

    /// The `NotchPanelController` factory. Hides the previous widget first.
    public func makeWidget(_ widget: Widget) -> NSViewController {
        hideVisible()
        visible = widget
        let visit = UUID()
        widgetVisit = visit
        writeAuthorization = ClipboardWriteAuthorization()
        switch widget {
        case .nowPlaying:
            mediaCommands = MediaCommandAuthorization()
            if case .some(.ready(_)) = media { loadArtwork(lastSnapshot) }
            let controller = NowPlayingWidgetController(state: nowPlayingState(), onAction: action(visit) { $0.nowPlaying($1) })
            nowPlayingView = controller
            updateElapsedTask()
            return controller
        case .calendar:
            let controller = CalendarWidgetController(state: calendarState(), onAction: action(visit) { $0.calendar($1) })
            calendarView = controller
            return controller
        case .mirror:
            let preview = CameraPreviewView(frame: .zero)
            cameraPreview = preview
            cameraLease?.feed.connectPreview(to: preview.previewLayer)
            let controller = MirrorWidgetController(status: mirrorStatus(), preview: preview, onAction: action(visit) { $0.mirror($1) })
            mirrorView = controller
            return controller
        case .clipboard:
            let controller = ClipboardWidgetController(state: clipboardState(), onAction: action(visit) { $0.clipboardAction($1) })
            clipboardView = controller
            subscribeClipboard()
            return controller
        case .shelf:
            let controller = FileShelfWidgetController(state: shelfState(), onAction: action(visit) { $0.shelfAction($1) })
            shelfView = controller
            loadShelf(reload: false)
            return controller
        }
    }

    /// Cancels visible work and drops view references. A shelf copy job keeps going.
    public func dismiss() { hideVisible() }

    /// The panel owns this controller beside Now Playing. It shares the
    /// existing Calendar feed and never replaces the primary widget.
    public func makeCalendarCompanion() -> NSViewController {
        precondition(visible == .nowPlaying)
        calendarIsCompanion = true
        let visit = UUID()
        calendarVisit = visit
        let controller = CalendarWidgetController(state: calendarState(), onAction: action(visit) { $0.calendar($1) })
        calendarView = controller
        return controller
    }

    public func removeCalendarCompanion() {
        calendarIsCompanion = false
        calendarVisit = nil
        if visible != .calendar { calendarView = nil }
    }

    /// Re-renders the visible widget, for example after the app became active
    /// and permission status may have changed.
    public func refresh() {
        configureShelfExpiry()
        switch visible {
        case .nowPlaying: nowPlayingView?.update(nowPlayingState())
        case .calendar: calendarView?.update(calendarState())
        case .mirror: mirrorView?.update(mirrorStatus())
        case .clipboard: clipboardView?.update(clipboardState())
        case .shelf: shelfView?.update(shelfState())
        case nil: break
        }
        if visible == .nowPlaying, calendarView != nil { refreshCalendar() }
        if let visible { onContentChange?(visible) }
    }

    private func hideVisible() {
        widgetVisit = nil; calendarVisit = nil
        mediaCommands?.revoke(); mediaCommands = nil
        writeAuthorization?.revoke()
        writeAuthorization = nil
        elapsedTask?.cancel(); elapsedTask = nil
        clipboardSubscription?.cancel(); clipboardSubscription = nil
        shelfLoad?.cancel(); shelfLoad = nil
        artworkPipeline.clear()
        artworkID = nil
        artwork = nil
        clipboardRecords = []
        clipboardThumbnails = [:]
        mirrorView?.setPreview(nil)
        cameraPreview = nil
        copiedID = nil
        nowPlayingView = nil
        calendarView = nil
        mirrorView = nil
        clipboardView = nil
        shelfView = nil
        visible = nil
        calendarIsCompanion = false
    }

    // MARK: Feeds. FeatureRuntime's factory calls these.

    public func startMediaFeed() -> any FeatureServiceHandle {
        let feed = MediaFeed(driver: MediaDriver(script: mediaScript, framework: mediaFramework)) { [weak self] state in
            self?.mediaChanged(state)
        }
        let lease = ServiceLease(feed: feed) { [weak self] in self?.mediaStopped() }
        mediaLease = lease
        media = .starting
        refreshNowPlaying()
        return lease
    }

    public func startCalendarFeed() -> any FeatureServiceHandle {
        let feed = CalendarFeed { [weak self] result in self?.agendaChanged(result) }
        let lease = ServiceLease(feed: feed) { [weak self] in self?.calendarStopped() }
        calendarLease = lease
        return lease
    }

    public func startClipboardFeed() -> any FeatureServiceHandle {
        let feed = ClipboardFeed(channel: pasteboard) { [weak self] sample in self?.captured(sample) }
        let lease = ServiceLease(feed: feed) { [weak self] in self?.clipboardLease = nil }
        clipboardLease = lease
        prepareClipboard()
        return lease
    }

    /// Only for a visible, permitted Mirror. `FeatureDemand` decides that.
    public func startCameraFeed() -> any FeatureServiceHandle {
        let feed = CameraFeed(driver: CameraDriver()) { [weak self] state in self?.cameraChanged(state) }
        let lease = ServiceLease(feed: feed) { [weak self] in self?.cameraStopped() }
        cameraLease = lease
        if let cameraPreview { feed.connectPreview(to: cameraPreview.previewLayer) }
        return lease
    }

    // MARK: Settings

    /// `ClipboardRepository.clear`, for Settings. Throws when it refused.
    public func clearClipboardHistory() async throws {
        try await clipboard.clear()
    }

    /// `ClipboardRepository.setPersistenceEnabled`, for Settings. Throws when it refused.
    public func setClipboardPersistence(_ enabled: Bool) async throws {
        try await clipboard.setPersistenceEnabled(enabled)
    }

    // MARK: Now Playing

    private func mediaChanged(_ state: MediaFeedState) {
        media = state
        if case .ready(let snapshot) = state {
            lastSnapshot = snapshot
            if let source = snapshot?.source { rememberName(source) }
            if visible == .nowPlaying { loadArtwork(snapshot) }
        }
        effects.widgetEvent(.media(state))
        refreshNowPlaying()
    }

    private func mediaStopped() {
        mediaLease = nil
        media = nil
        lastSnapshot = nil
        artworkPipeline.clear()
        artworkID = nil
        artwork = nil
        effects.widgetEvent(.media(.unavailable))
        refreshNowPlaying()
    }

    private func calendarStopped() {
        calendarLease = nil
        agenda = nil
        effects.widgetEvent(.calendar(.unavailable))
        refreshCalendar()
    }

    private func refreshNowPlaying() {
        nowPlayingView?.update(nowPlayingState())
        if nowPlayingView != nil { onContentChange?(.nowPlaying) }
        updateElapsedTask()
    }

    private func nowPlayingState(now: Date = .now) -> NowPlayingWidgetState {
        switch media {
        case nil, .unavailable?:
            return NowPlayingWidgetState(status: .noAccess)
        case .starting?, .ready?:
            guard let snapshot = lastSnapshot else {
                if case .starting? = media { return NowPlayingWidgetState(status: .loading) }
                return .empty
            }
            let sources = snapshot.source.map { [NowPlayingSourceOption(id: $0, name: sourceNames[$0] ?? $0.rawValue)] } ?? []
            return NowPlayingWidgetState(
                status: snapshot.playing ? .playing : .paused,
                title: snapshot.title, artist: snapshot.artist,
                artwork: snapshot.artworkID == artworkID ? artwork : nil,
                sources: sources, selectedSource: snapshot.source,
                elapsed: snapshot.elapsed(at: now) ?? 0, duration: snapshot.duration,
                canGoPrevious: snapshot.canSkip, canGoNext: snapshot.canSkip)
        }
    }

    /// The only timer: one second, while Now Playing is visible and playing.
    private func updateElapsedTask() {
        let hasLiveFrame: Bool
        if case .some(.ready(_)) = media { hasLiveFrame = true } else { hasLiveFrame = false }
        let ticking = hasLiveFrame && visible == .nowPlaying && nowPlayingView != nil && lastSnapshot?.playing == true
            && lastSnapshot?.duration != nil && mediaLease != nil
        guard ticking else {
            elapsedTask?.cancel(); elapsedTask = nil
            return
        }
        guard elapsedTask == nil else { return }
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let view = self.nowPlayingView, self.lastSnapshot?.playing == true else { return }
                view.update(self.nowPlayingState())
            }
        }
    }

    private func loadArtwork(_ snapshot: MediaSnapshot?) {
        guard let snapshot, let id = snapshot.artworkID, let data = snapshot.artwork else {
            artworkPipeline.clear()
            artworkID = nil
            artwork = nil
            return
        }
        guard id != artworkID else { return }
        artworkID = id
        artwork = nil
        artworkPipeline.submit(id: id, bytes: data)
    }

    private func rememberName(_ id: ApplicationID) {
        guard sourceNames[id] == nil else { return }
        if sourceNames.count >= 16 { sourceNames.removeAll() }
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: id.rawValue).first?.localizedName {
            sourceNames[id] = name
        }
    }

    private func nowPlaying(_ action: NowPlayingWidgetAction) {
        switch action {
        case .togglePlayPause: if let mediaCommands { sendMedia(.toggle, authorization: mediaCommands) }
        case .previous: if let mediaCommands { sendMedia(.previous, authorization: mediaCommands) }
        case .next: if let mediaCommands { sendMedia(.next, authorization: mediaCommands) }
        case .seek(let seconds): if let mediaCommands { sendMedia(.seek(seconds), authorization: mediaCommands) }
        case .selectSource(let id): openApplication(id)
        case .openSource:
            if let id = lastSnapshot?.source { openApplication(id) } else { effects.report(.mediaOpenSource) }
        case .checkAgain:
            effects.retry(.media)
        }
    }

    private func sendMedia(_ control: MediaControl, authorization: MediaCommandAuthorization? = nil) {
        guard let feed = mediaLease?.feed else {
            effects.report(.mediaCommand)
            return
        }
        Task { @MainActor [weak self] in
            let accepted = await feed.send(control, authorization: authorization)
            if !accepted { self?.effects.report(.mediaCommand) }
        }
    }

    /// The runtime checks the live locked phase and saved lock-media choice
    /// before forwarding. The existing demand-owned media lease is reused.
    func sendLockScreenControl(_ control: MediaControl, authorization: MediaCommandAuthorization) {
        sendMedia(control, authorization: authorization)
    }

    /// Activates the running app, or launches it by bundle ID.
    private func openApplication(_ id: ApplicationID) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id.rawValue).first {
            if !running.activate() { effects.report(.mediaOpenSource) }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.rawValue) else {
            effects.report(.mediaOpenSource)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: Calendar

    private func agendaChanged(_ result: AgendaReadResult) {
        agenda = result
        effects.widgetEvent(.calendar(result))
        refreshCalendar()
    }

    private func refreshCalendar() {
        calendarView?.update(calendarState())
        if calendarView != nil { onContentChange?(.calendar) }
    }

    private func calendarState(now: Date = .now) -> CalendarWidgetState {
        let access = PermissionAccess.status(.calendar)
        guard access == .allowed else { return access == .notAsked ? .needsPermission : .unavailable }
        let calendar = Calendar.current
        if case .ready(let snapshot)? = agenda, snapshot.today == calendar.startOfDay(for: now) {
            let afterTomorrow = calendar.date(byAdding: .day, value: 1, to: snapshot.tomorrow) ?? snapshot.tomorrow
            // 0.21.35: events still running from now to the end of tomorrow,
            // the 20 earliest, grouped by the day they start.
            let upcoming = snapshot.entries.filter { $0.end > now && $0.start < afterTomorrow }
                .sorted { $0.start < $1.start }.prefix(CalendarWidgetController.maximumRowsPerDay)
            func rows(_ start: Date, _ end: Date) -> [CalendarWidgetEvent] {
                upcoming.filter { $0.start >= start && $0.start < end }.map { entry in
                    CalendarWidgetEvent(id: entry.id, title: entry.title, location: entry.location,
                                        start: entry.start, end: entry.end, isAllDay: entry.allDay,
                                        color: CalendarWidgetColor(red: entry.color.red, green: entry.color.green,
                                                                   blue: entry.color.blue))
                }
            }
            return .events(today: rows(snapshot.today, snapshot.tomorrow),
                           tomorrow: rows(snapshot.tomorrow, afterTomorrow))
        }
        if agenda == .needsPermission { return .needsPermission }
        if agenda == nil { return .loading }
        return .unavailable
    }

    private func calendar(_ action: CalendarWidgetAction) {
        switch action {
        case .requestAccess:
            Task { @MainActor [weak self] in
                await self?.effects.requestAccess(.calendar)
                self?.calendarView?.update(self?.calendarState() ?? .unavailable)
            }
        case .openSettings:
            effects.openSettings(.calendar)
        case .checkAgain:
            if let feed = calendarLease?.feed { feed.refresh() } else { effects.retry(.calendar) }
        case .openCalendar(let day):
            openCalendar(day)
        }
    }

    /// Opens Calendar on the day with the `calshow:` URL, whose value is the
    /// day's start in the current time zone, in seconds since 2001.
    private func openCalendar(_ day: CalendarWidgetDay) {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: .now)
        let date = day == .today ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        guard let url = URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))"),
              NSWorkspace.shared.open(url) else {
            effects.report(.calendarOpen)
            return
        }
    }

    // MARK: Mirror

    private func cameraChanged(_ state: CameraState) {
        camera = state
        effects.widgetEvent(.camera(state))
        mirrorView?.update(mirrorStatus())
    }

    private func cameraStopped() {
        cameraLease = nil
        camera = nil
        effects.widgetEvent(.camera(nil))
        mirrorView?.update(mirrorStatus())
    }

    private func mirrorStatus() -> MirrorWidgetStatus {
        if let camera, cameraLease != nil {
            switch camera {
            case .starting: return .starting
            case .running: return .running
            case .needsPermission:
                return PermissionAccess.status(.camera) == .notAsked ? .needsPermission : .denied
            case .unavailable: return .unavailable
            case .interrupted: return .interrupted
            case .failed: return .failed
            }
        }
        switch PermissionAccess.status(.camera) {
        case .notAsked: return .needsPermission
        case .notAllowed: return .denied
        // Allowed but no feed: the runtime did not start it, or it failed.
        case .allowed, .unknown: return .failed
        }
    }

    private func mirror(_ action: MirrorWidgetAction) {
        switch action {
        case .requestPermission:
            Task { @MainActor [weak self] in
                await self?.effects.requestAccess(.camera)
                self?.mirrorView?.update(self?.mirrorStatus() ?? .failed)
            }
        case .openSettings: effects.openSettings(.camera)
        case .retry: effects.retry(.camera)
        }
    }

    // MARK: Clipboard

    private func captured(_ sample: ClipboardSample) {
        guard pendingCaptures < Self.maximumPendingCaptures else {
            effects.report(.clipboardCaptureDropped)
            return
        }
        pendingCaptures += 1
        let clipboard = clipboard
        Task { @MainActor [weak self] in
            do { try await clipboard.capture(sample.payload, at: sample.capturedAt) }
            catch { self?.effects.report(.clipboardCapture) }
            self?.pendingCaptures -= 1
        }
    }

    /// Restores saved history once, with the saved persistence choice.
    /// `ClipboardRepository.prepare` ignores later calls after it succeeded.
    private func prepareClipboard() {
        guard clipboardPrepare == nil else { return }
        let clipboard = clipboard
        let persistence = preferences.value(for: Preferences.clipboardPersistenceEnabled)
        clipboardPrepare = Task { @MainActor [weak self] in
            do { try await clipboard.prepare(persistenceEnabled: persistence) }
            catch { self?.effects.report(.clipboardRestore) }
            self?.clipboardPrepare = nil
        }
    }

    private func subscribeClipboard() {
        prepareClipboard()
        let clipboard = clipboard
        clipboardSubscription = Task { @MainActor [weak self] in
            for await records in await clipboard.updates() {
                guard !Task.isCancelled else { return }
                self?.clipboardChanged(records)
            }
        }
    }

    private func clipboardChanged(_ records: [ClipboardRecord]) {
        clipboardRecords = Array(records.prefix(Self.maximumClipboardRows))
        let ids = Set(clipboardRecords.map(\.id))
        clipboardThumbnails = clipboardThumbnails.filter { ids.contains($0.key) }
        if let copiedID, !ids.contains(copiedID) { self.copiedID = nil }
        clipboardView?.update(clipboardState())
    }

    private func clipboardState() -> ClipboardWidgetState {
        guard clipboardView != nil || visible == .clipboard else { return ClipboardWidgetState() }
        let items = clipboardRecords.map { record -> ClipboardWidgetItem in
            var kind = ClipboardWidgetKind.other
            var color: ClipboardWidgetColor?
            var image: NSImage?
            switch record.payload {
            case .text(let text, .color):
                kind = .color
                color = ClipboardColor.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)).map {
                    ClipboardWidgetColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
                }
            case .text(_, .url): kind = .url
            case .text(_, .text): kind = .text
            case .files: kind = .file
            case .image(_, let thumbnail, _, _):
                kind = .image
                image = thumbnailImage(record.id, thumbnail)
            case .unsupported: kind = .other
            }
            return ClipboardWidgetItem(id: record.id, preview: record.preview, kind: kind, image: image,
                                       color: color, hasPayload: record.canCopy, link: record.browserURL,
                                       capturedAt: record.capturedAt)
        }
        return ClipboardWidgetState(items: items, copiedID: copiedID)
    }

    /// Only the stored 64 px thumbnail, never the full image.
    private func thumbnailImage(_ id: UUID, _ data: Data?) -> NSImage? {
        if let cached = clipboardThumbnails[id] { return cached }
        guard let data, data.count <= ClipboardHistory.maximumThumbnailBytes, let image = NSImage(data: data) else { return nil }
        clipboardThumbnails[id] = image
        return image
    }

    private func clipboardAction(_ action: ClipboardWidgetAction) {
        let clipboard = clipboard
        switch action {
        case .copy(let id):
            guard visible == .clipboard, let authorization = writeAuthorization else { return }
            Task { @MainActor [weak self] in
                let record = await clipboard.record(for: id)
                guard let self, self.visible == .clipboard, self.writeAuthorization === authorization else { return }
                guard let record, record.canCopy,
                      await self.writePasteboard(record.payload, authorization: authorization) else {
                    if self.writeAuthorization === authorization { self.effects.report(.clipboardCopy) }
                    return
                }
                guard self.visible == .clipboard, self.writeAuthorization === authorization else { return }
                self.copiedID = id
                self.clipboardView?.update(self.clipboardState())
            }
        case .remove(let id):
            Task { @MainActor [weak self] in
                do { try await clipboard.remove(id) } catch { self?.effects.report(.clipboardRemove) }
            }
        case .clearAll:
            Task { @MainActor [weak self] in
                do { try await clipboard.clear() } catch { self?.effects.report(.clipboardClear) }
            }
        case .openLink(let id):
            guard let url = clipboardRecords.first(where: { $0.id == id })?.browserURL,
                  NSWorkspace.shared.open(url) else {
                effects.report(.clipboardOpenLink)
                return
            }
        }
    }

    /// Writes through the running feed so it skips its own change, or through
    /// the shared channel when collection is off. True only on a write ack.
    private func writePasteboard(_ payload: ClipboardPayload, authorization: ClipboardWriteAuthorization) async -> Bool {
        guard writeAuthorization === authorization else { return false }
        if let feed = clipboardLease?.feed { return await feed.copyBack(payload, authorization: authorization) }
        return await pasteboard.write(payload, authorization: authorization) != nil
    }

    // MARK: File Shelf

    private var requestedShelfExpiry: Double? {
        guard preferences.value(for: Preferences.notchEnabled),
              preferences.value(for: Preferences.shelfEnabled) else { return nil }
        let days = preferences.value(for: Preferences.shelfExpiryDays)
        return [1.0, 3, 7].contains(days) ? days : nil
    }

    private func configureShelfExpiry() {
        let days = requestedShelfExpiry
        guard days != shelfExpiry else { return }
        shelfExpiry = days
        maintainShelf()
    }

    /// A saved positive expiry sweeps on configure and copy completion. The
    /// shelf view also sweeps before loading. No idle expiry timer is created.
    private func maintainShelf() {
        shelfMaintenance?.cancel(); shelfMaintenance = nil
        guard let days = requestedShelfExpiry else { return }
        let shelf = shelf
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        shelfMaintenance = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await shelf.expire(olderThan: cutoff)
            } catch {
                guard !Task.isCancelled else { return }
                self?.effects.report(.shelfRemove)
            }
        }
    }

    private func loadShelf(reload: Bool) {
        shelfLoad?.cancel()
        let shelf = shelf
        let cutoff = requestedShelfExpiry.map { Date().addingTimeInterval(-$0 * 86_400) }
        shelfLoad = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                if reload { _ = try await shelf.reload() }
                if let cutoff { try await shelf.expire(olderThan: cutoff) }
                let files = try await shelf.load()
                var urls: [UUID: URL] = [:]
                for file in files {
                    guard !Task.isCancelled else { return }
                    if let url = try? await shelf.payload(for: file.id) { urls[file.id] = url }
                }
                guard let self, !Task.isCancelled else { return }
                self.shelfLoad = nil
                self.shelfFiles = files
                self.shelfURLs = urls
                self.requestShelfThumbnails()
                self.shelfFailed = false
                self.shelfLoaded = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.shelfLoad = nil
                // Keep the files and the manifest. Only Try Again reads again.
                self.shelfFailed = true
                self.effects.report(.shelfLoad)
            }
            self?.refreshShelf()
        }
    }

    private func shelfState() -> FileShelfWidgetState {
        if shelfFailed { return FileShelfWidgetState(items: copyingRows, status: .failed) }
        let rows = shelfFiles.map { file in
            FileShelfWidgetItem(id: file.id, name: file.fileName, image: shelfThumbnails[file.id],
                                dragURL: shelfURLs[file.id],
                                status: shelfURLs[file.id] == nil ? .failed : .ready, addedAt: file.addedAt)
        }
        let status: FileShelfWidgetStatus = copyJob != nil ? .busy : (shelfLoaded ? .ready : .loading)
        return FileShelfWidgetState(items: copyingRows + rows, status: status)
    }

    /// One QuickLook request per file, for the 100 newest. A file with no
    /// thumbnail gets its Finder icon.
    private func requestShelfThumbnails() {
        let ids = Set(shelfFiles.map(\.id))
        shelfThumbnails = shelfThumbnails.filter { ids.contains($0.key) }
        guard visible == .shelf else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for file in shelfFiles.prefix(100) where shelfThumbnails[file.id] == nil {
            guard let url = shelfURLs[file.id], thumbnailRequests.insert(file.id).inserted else { continue }
            let id = file.id
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                       scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                nonisolated(unsafe) let image = representation?.nsImage
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.thumbnailRequests.remove(id)
                    guard self.shelfFiles.contains(where: { $0.id == id }) else { return }
                    self.shelfThumbnails[id] = image ?? NSWorkspace.shared.icon(forFile: url.path)
                    self.refreshShelf()
                }
            }
        }
    }

    private func refreshShelf() {
        shelfView?.update(shelfState())
        if shelfView != nil { onContentChange?(.shelf) }
    }

    private func shelfAction(_ action: FileShelfWidgetAction) {
        switch action {
        case .drop(let urls): drop(urls)
        case .open(let id):
            guard let url = shelfURLs[id], NSWorkspace.shared.open(url) else { effects.report(.shelfOpen); return }
        case .showInFinder(let id):
            guard let url = shelfURLs[id] else { effects.report(.shelfOpen); return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .airDrop(let id):
            guard let url = shelfURLs[id], let service = NSSharingService(named: .sendViaAirDrop),
                  service.canPerform(withItems: [url]) else { effects.report(.shelfShare); return }
            service.perform(withItems: [url])
        case .copy(let id):
            guard visible == .shelf, let authorization = writeAuthorization,
                  let url = shelfURLs[id] else { effects.report(.shelfPasteboard); return }
            Task { @MainActor [weak self] in
                guard let self, self.writeAuthorization === authorization else { return }
                if !(await self.writePasteboard(.files([url]), authorization: authorization)),
                   self.writeAuthorization === authorization { self.effects.report(.shelfPasteboard) }
            }
        case .remove(let id):
            if copyingRows.contains(where: { $0.id == id }) {
                copyJob?.cancel(id)
                copyingRows.removeAll { $0.id == id }
                refreshShelf()
            } else { removeShelf { try await $0.remove([id]) } }
        case .clearAll:
            copyJob?.cancelAll()
            copyingRows = []
            removeShelf { try await $0.clear() }
        case .retry: loadShelf(reload: true)
        }
    }

    /// Removes shelf copies only. `ShelfFiles` never touches an original.
    private func removeShelf(_ work: @escaping @Sendable (ShelfFiles) async throws -> Void) {
        let shelf = shelf
        Task { @MainActor [weak self] in
            do { try await work(shelf) } catch { self?.effects.report(.shelfRemove) }
            guard let self, self.visible == .shelf else { return }
            self.loadShelf(reload: false)
        }
    }

    /// True when the File Shelf view of the current visit can take a drop:
    /// the notch and shelf are on, the list is loaded and no copy job runs.
    /// It reads no file. The window asks this during a drag.
    public var acceptsShelfDrop: Bool {
        visible == .shelf && widgetVisit != nil && shelfView != nil
            && copyJob == nil && shelfLoaded && !shelfFailed
            && preferences.value(for: Preferences.notchEnabled)
            && preferences.value(for: Preferences.shelfEnabled)
    }

    /// A drop that landed on the notch window outside the shelf root. Same
    /// checks and the same copy job as the root's `.drop`. Returns false and
    /// starts nothing when `acceptsShelfDrop` is false or no URL is a file.
    public func acceptShelfDrop(_ urls: [URL]) -> Bool {
        guard acceptsShelfDrop, urls.contains(where: \.isFileURL) else { return false }
        drop(urls)
        return copyJob != nil
    }

    /// One copy job at a time. It may outlive the panel. It holds no view.
    private func drop(_ urls: [URL]) {
        guard copyJob == nil else { effects.report(.shelfBusy); return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { effects.report(.shelfCopy); return }
        if files.count > Self.maximumDropFiles { effects.report(.shelfDropLimited) }
        let batch = files.prefix(Self.maximumDropFiles).map { ShelfCopyBatch.Request(source: $0) }
        copyingRows = batch.map { FileShelfWidgetItem(id: $0.id, name: $0.source.lastPathComponent, status: .copying) }
        let shelf = shelf
        copyJob = ShelfCopyBatch(requests: batch, copy: { try await shelf.addCopy(of: $0) },
            remove: { try await shelf.remove([$0]) }, progress: { [weak self] id in
                self?.copyingRows.removeAll { $0.id == id }
                if self?.visible == .shelf { self?.loadShelf(reload: false) }
            }, finished: { [weak self] added, failed in
            self?.copyFinished(added: added, failed: failed)
        })
        copyJob?.start()
        refreshShelf()
    }

    private func copyFinished(added: Int, failed: Int) {
        copyJob = nil
        copyingRows = []
        maintainShelf()
        if failed > 0 { effects.report(.shelfCopy) }
        effects.widgetEvent(.shelfCopyFinished(added: added, failed: failed))
        if visible == .shelf { loadShelf(reload: false) }
    }
}
