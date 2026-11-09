import Darwin
import Foundation
import OSLog
import FluxCore

public enum MediaFeedState: Equatable, Sendable {
    case starting, ready(MediaSnapshot?), unavailable
}

public enum MediaControl: Sendable { case toggle, previous, next, seek(TimeInterval) }

/// FileHandle's callback admits at most 8 MiB and schedules one actor drain.
/// Lock ownership covers only bytes and queue state, never decoding or UI work.
private final class MediaMailbox: @unchecked Sendable {
    enum Item { case bytes(Data), overflow, empty }
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bytes = 0
    private var draining = false
    private var overflow = false

    func offer(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if bytes + data.count > MediaStream.maximumLineBytes { overflow = true }
        else { chunks.append(data); bytes += data.count }
        if draining { return false }
        draining = true
        return true
    }

    func take() -> Item {
        lock.lock(); defer { lock.unlock() }
        if overflow { chunks.removeAll(); bytes = 0; overflow = false; draining = false; return .overflow }
        guard !chunks.isEmpty else { draining = false; return .empty }
        let data = chunks.removeFirst()
        bytes -= data.count
        return .bytes(data)
    }
}

/// Foundation permits cross-thread Process status and termination. The helper
/// is immutable here so a finite stop task can retain its exact process handle.
private final class MediaProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        let retained = MediaProcessHandle(process)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            if retained.process.isRunning { kill(retained.process.processIdentifier, SIGKILL) }
        }
    }
}

/// Owns the pinned adapter's entitled Perl helper. It receives events, with
/// no elapsed-time poll. Metadata and artwork decoding stay off the UI actor.
public actor MediaDriver {
    public nonisolated let updates: AsyncStream<MediaFeedState>
    private let output: AsyncStream<MediaFeedState>.Continuation
    private let script: URL
    private let framework: URL
    private var process: Process?
    private var pipe: Pipe?
    private var parser = MediaStream()
    private var active = false
    private var generation: UInt64 = 0
    private var startedAt: Date?
    private var restartCount = 0
    private var restart: Task<Void, Never>?
    private var readiness: Task<Void, Never>?
    private let log = Logger(subsystem: "com.flux.menubar", category: "media-driver")
    private struct Command {
        let process: Process
        let result: CheckedContinuation<Bool, Never>
        var deadline: Task<Void, Never>?
    }
    private var commands: [UUID: Command] = [:]

    public init(script: URL, framework: URL) {
        self.script = script
        self.framework = framework
        let channel = AsyncStream<MediaFeedState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = channel.stream
        output = channel.continuation
    }

    public func start() {
        guard !active else { return }
        active = true
        launch()
    }

    public func stop() {
        active = false
        generation &+= 1
        restart?.cancel(); restart = nil
        readiness?.cancel(); readiness = nil
        closeStream()
        for id in Array(commands.keys) { finishCommand(id, success: false) }
        output.finish()
    }

    public func send(_ command: MediaControl, authorization: MediaCommandAuthorization? = nil) async -> Bool {
        guard active, process?.isRunning == true, commands.count < 4 else { return false }
        let arguments: [String]
        switch command {
        case .toggle: arguments = ["send", "2"]
        case .previous: arguments = ["send", "5"]
        case .next: arguments = ["send", "4"]
        case .seek(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= 365 * 86400 else { return false }
            arguments = ["seek", String(Int64(seconds * 1_000_000))]
        }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let process = makeProcess(arguments)
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] ended in
                let success = ended.terminationStatus == 0
                Task { await self?.finishCommand(id, success: success) }
            }
            commands[id] = Command(process: process, result: continuation)
            do {
                if let authorization {
                    guard try authorization.perform({ try process.run() }) else {
                        finishCommand(id, success: false)
                        return
                    }
                } else { try process.run() }
                commands[id]?.deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    await self?.finishCommand(id, success: false)
                }
            } catch { finishCommand(id, success: false) }
        }
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func launch() {
        guard active, process == nil else { return }
        guard script.isFileURL, framework.isFileURL,
              FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: framework.path) else {
            output.yield(.unavailable)
            return
        }
        generation &+= 1
        let token = generation
        parser = MediaStream()
        output.yield(.starting)
        let process = makeProcess(["stream"])
        let pipe = Pipe()
        let mailbox = MediaMailbox()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            if mailbox.offer(bytes) { Task { await self?.drain(mailbox, generation: token) } }
        }
        process.terminationHandler = { [weak self] _ in Task { await self?.ended(generation: token) } }
        self.process = process
        self.pipe = pipe
        do {
            try process.run()
            startedAt = .now
            log.info("Media stream started")
            readiness = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                await self?.failed(generation: token)
            }
        } catch { failed(generation: token) }
    }

    private func drain(_ mailbox: MediaMailbox, generation token: UInt64) {
        guard active, generation == token else { return }
        while true {
            switch mailbox.take() {
            case .empty: return
            case .overflow: failed(generation: token); return
            case .bytes(let bytes):
                do {
                    // Pipe callbacks can return more than one parser chunk.
                    var offset = 0
                    while offset < bytes.count {
                        let end = min(offset + 65536, bytes.count)
                        let states = try parser.append(bytes.subdata(in: offset..<end))
                        if !states.isEmpty { readiness?.cancel(); readiness = nil }
                        for state in states { output.yield(.ready(state)) }
                        offset = end
                    }
                } catch { failed(generation: token); return }
            }
        }
    }

    private func ended(generation token: UInt64) { failed(generation: token) }

    private func failed(generation token: UInt64) {
        guard active, generation == token else { return }
        generation &+= 1
        readiness?.cancel(); readiness = nil
        if let startedAt, Date().timeIntervalSince(startedAt) >= 60 { restartCount = 0 }
        closeStream()
        output.yield(.unavailable)
        log.error("Media stream unavailable")
        guard restartCount < 3 else { return }
        let delay = [1.0, 3, 8][restartCount]
        restartCount += 1
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.launch()
        }
    }

    private func closeStream() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        pipe = nil
        if let process {
            process.terminationHandler = nil
            MediaProcessHandle(process).stop()
        }
        process = nil
        parser = MediaStream()
    }

    private func finishCommand(_ id: UUID, success: Bool) {
        guard let command = commands.removeValue(forKey: id) else { return }
        command.deadline?.cancel()
        command.process.terminationHandler = nil
        MediaProcessHandle(command.process).stop()
        command.result.resume(returning: success)
    }
}

@MainActor public final class MediaFeed: FeatureServiceHandle {
    public var onChange: ((MediaFeedState) -> Void)?
    private let driver: MediaDriver
    private var events: Task<Void, Never>?
    private var active = true

    public init(driver: MediaDriver, onChange: @escaping (MediaFeedState) -> Void) {
        self.driver = driver
        self.onChange = onChange
        events = Task { @MainActor [weak self, driver] in
            await driver.start()
            for await state in driver.updates {
                guard let self, self.active, !Task.isCancelled else { return }
                self.onChange?(state)
            }
        }
    }

    deinit {
        events?.cancel()
        let driver = driver
        Task { await driver.stop() }
    }

    public func send(_ command: MediaControl, authorization: MediaCommandAuthorization? = nil) async -> Bool {
        guard active else { return false }
        return await driver.send(command, authorization: authorization)
    }

    public func stop() {
        guard active else { return }
        active = false
        onChange = nil
        events?.cancel(); events = nil
        let driver = driver
        Task { await driver.stop() }
    }
}
