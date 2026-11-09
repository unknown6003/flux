#if FLUX_PERFORMANCE_TRACE
import Darwin
import Foundation

public enum PerformanceTraceCode: String, Codable, Sendable, CaseIterable {
    case appReady, appStop, sessionSleep, sessionWake, sessionLock, sessionUnlock
    case spaceChanged, displayChanged, timeZoneChanged, clockChanged
    case applicationActivated, sessionRefresh, phaseChanged, notchRefresh
    case activitiesReconcile, menuControlsRender, usageRecordAdmitted, usageFlushStarted
    case httpEventsStarted, httpFlagsStarted, httpLogsStarted
    case httpSucceeded, httpRejected, httpRetryable, httpFailed, httpCancelled
}

public enum PerformanceTraceError: Error, Equatable, Sendable {
    case invalidDirectory, alreadyStarted, alreadyFinished, encodingFailed
    case outputExists, writeFailed
}

public final class PerformanceTraceRecorder: @unchecked Sendable {
    private struct Event: Encodable {
        let uptimeNanoseconds: UInt64
        let code: PerformanceTraceCode
    }

    private struct Document: Encodable {
        let processID: Int32
        let clock: String
        let events: [Event]
        let dropped: UInt64
    }

    private let lock = NSLock()
    private let directory: URL
    private let processID = getpid()
    private var directoryFD: Int32
    private var events: [Event] = []
    private var dropped: UInt64 = 0
    private var finished = false

    public init(directory: URL) throws {
        guard directory.isFileURL, directory.query == nil, directory.fragment == nil else {
            throw PerformanceTraceError.invalidDirectory
        }
        let requested = directory.standardizedFileURL
        let name = requested.lastPathComponent
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard name.hasPrefix("flux-performance-"), name.count > "flux-performance-".count,
              requested.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == parent.path else {
            throw PerformanceTraceError.invalidDirectory
        }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PerformanceTraceError.invalidDirectory }
        defer { Darwin.close(parentFD) }
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw PerformanceTraceError.invalidDirectory }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              attributes.st_uid == getuid(),
              attributes.st_mode & 0o7777 == 0o700 else {
            Darwin.close(fd)
            throw PerformanceTraceError.invalidDirectory
        }
        self.directory = parent.appendingPathComponent(name, isDirectory: true)
        self.directoryFD = fd
        events.reserveCapacity(1_024)
    }

    deinit {
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }

    public func record(_ code: PerformanceTraceCode) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard events.count < 1_024 else {
            if dropped < UInt64.max { dropped += 1 }
            return
        }
        events.append(Event(uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), code: code))
    }

    public func finish() throws -> URL {
        lock.lock()
        guard !finished else {
            lock.unlock()
            throw PerformanceTraceError.alreadyFinished
        }
        finished = true
        let fd = directoryFD
        directoryFD = -1
        let document = Document(processID: processID, clock: "CLOCK_UPTIME_RAW", events: events, dropped: dropped)
        lock.unlock()
        defer { Darwin.close(fd) }

        guard let data = try? JSONEncoder().encode(document), data.count <= 131_072 else {
            throw PerformanceTraceError.encodingFailed
        }
        var heldAttributes = stat()
        var pathAttributes = stat()
        guard fstat(fd, &heldAttributes) == 0, lstat(directory.path, &pathAttributes) == 0,
              pathAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              pathAttributes.st_dev == heldAttributes.st_dev,
              pathAttributes.st_ino == heldAttributes.st_ino,
              heldAttributes.st_uid == getuid(), heldAttributes.st_mode & 0o7777 == 0o700 else {
            throw PerformanceTraceError.invalidDirectory
        }
        let name = "trace-\(processID).json"
        let outputFD = name.withCString {
            openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard outputFD >= 0 else {
            throw errno == EEXIST ? PerformanceTraceError.outputExists : PerformanceTraceError.writeFailed
        }
        var outputOpen = true
        var complete = false
        defer {
            if outputOpen { Darwin.close(outputFD) }
            if !complete { name.withCString { _ = unlinkat(fd, $0, 0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw PerformanceTraceError.encodingFailed }
            var offset = 0
            var attempts = 0
            while offset < bytes.count {
                guard attempts < 256 else { throw PerformanceTraceError.writeFailed }
                attempts += 1
                let written = Darwin.write(outputFD, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw PerformanceTraceError.writeFailed }
                offset += written
            }
        }
        let closeResult = Darwin.close(outputFD)
        outputOpen = false
        guard closeResult == 0 else { throw PerformanceTraceError.writeFailed }
        complete = true
        return directory.appendingPathComponent(name)
    }
}

public enum PerformanceTrace {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var recorder: PerformanceTraceRecorder?
        var hasStarted = false
    }

    private static let state = State()

    public static var isEnabled: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.recorder != nil
    }

    public static func begin(directory: URL) throws {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.hasStarted else { throw PerformanceTraceError.alreadyStarted }
        state.recorder = try PerformanceTraceRecorder(directory: directory)
        state.hasStarted = true
    }

    public static func record(_ code: PerformanceTraceCode) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.recorder?.record(code)
    }

    public static func finish() throws -> URL? {
        state.lock.lock()
        let recorder = state.recorder
        state.recorder = nil
        state.lock.unlock()
        return try recorder?.finish()
    }
}
#endif
