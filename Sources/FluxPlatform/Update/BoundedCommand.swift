import Darwin
import Foundation

public enum BoundedCommandError: Error, Equatable { case launch, failed(Int32), timedOut, cancelled }

private final class CommandProcess: @unchecked Sendable {
    let value: Process
    init(_ value: Process) { self.value = value }
    func terminate() {
        guard value.isRunning else { return }
        value.terminate()
        let owner = self
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            if owner.value.isRunning { kill(owner.value.processIdentifier, SIGKILL) }
        }
    }
}

/// Finite install commands run off the UI actor. A shell job owns its own
/// process group, so a deadline or cancellation also stops descendants.
public actor BoundedCommand {
    private struct Running {
        let process: CommandProcess
        let result: CheckedContinuation<Void, any Error>
        var reason: BoundedCommandError?
        var deadline: Task<Void, Never>?
    }
    private var running: [UUID: Running] = [:]
    public init() {}

    public func run(_ executable: URL, arguments: [String], seconds: UInt) async throws {
        try Task.checkCancellation()
        guard executable.isFileURL, executable.path.hasPrefix("/"), (1...180).contains(seconds) else {
            throw BoundedCommandError.launch
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { result.resume(throwing: BoundedCommandError.cancelled); return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", Self.supervisor, "flux-command", String(seconds), executable.path] + arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { await self?.ended(id, status: status) }
                }
                running[id] = Running(process: CommandProcess(process), result: result)
                do {
                    try process.run()
                    running[id]?.deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(seconds + 2)) } catch { return }
                        await self?.stop(id, reason: .timedOut)
                    }
                } catch { ended(id, status: -1) }
            }
        } onCancel: { Task { await self.stop(id, reason: .cancelled) } }
    }

    private func stop(_ id: UUID, reason: BoundedCommandError) {
        guard running[id] != nil else { return }
        running[id]?.reason = reason
        running[id]?.process.terminate()
    }

    private func ended(_ id: UUID, status: Int32) {
        guard let command = running.removeValue(forKey: id) else { return }
        command.deadline?.cancel()
        if let reason = command.reason { command.result.resume(throwing: reason) }
        else if status == 124 { command.result.resume(throwing: BoundedCommandError.timedOut) }
        else if status != 0 { command.result.resume(throwing: BoundedCommandError.failed(status)) }
        else { command.result.resume() }
    }

    private static let supervisor = #"""
    trap '' HUP
    set -m
    limit=$1
    shift
    "$@" &
    child=$!
    stop() {
      kill -TERM -- "-$child" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$child" 2>/dev/null || true
      wait "$child" 2>/dev/null
    }
    trap 'stop; exit 124' TERM INT
    deadline=$((SECONDS + limit))
    while kill -0 "$child" 2>/dev/null; do
      if [ "$SECONDS" -ge "$deadline" ]; then stop; exit 124; fi
      sleep 0.05
    done
    wait "$child"
    result=$?
    if kill -0 -- "-$child" 2>/dev/null; then stop; fi
    exit "$result"
    """#
}
