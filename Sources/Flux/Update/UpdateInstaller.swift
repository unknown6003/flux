import Foundation
import Darwin

/// Prepares a complete replacement before Flux quits. Only the final renames
/// and relaunch run in the detached helper.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case notWritable
        case invalidApp
        case command(String)
        case timeout(String)
        case helperNotReady

        var errorDescription: String? {
            switch self {
            case .notWritable: return "Flux's install location isn't writable."
            case .invalidApp: return "The update image doesn't contain the expected Flux version."
            case .command(let name): return "The update couldn't finish \(name). Your installed app is unchanged."
            case .timeout(let name): return "The update timed out during \(name). Your installed app is unchanged."
            case .helperNotReady: return "The update helper didn't start. Your installed app is unchanged."
            }
        }
    }

    static func prepareAndLaunch(dmg: URL, installURL: URL, version: String) throws {
        let fm = FileManager.default
        let parent = installURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw Failure.notWritable
        }
        let token = UUID().uuidString
        let workspace = fm.temporaryDirectory.appendingPathComponent("flux-update-\(token)")
        let mount = workspace.appendingPathComponent("volume")
        let staged = parent.appendingPathComponent(".Flux-update-\(token).app")
        let backup = parent.appendingPathComponent(".Flux-backup-\(token).app")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        var handedOff = false
        var attached = false
        defer {
            if attached {
                try? run(["/usr/bin/hdiutil", "detach", mount.path, "-force", "-quiet"], seconds: 15)
            }
            try? fm.removeItem(at: dmg)
            if !handedOff {
                try? fm.removeItem(at: staged)
                try? fm.removeItem(at: workspace)
            }
        }
        // A known mount point also permits cleanup after an attach timeout.
        attached = true
        try run(["/usr/bin/hdiutil", "attach", dmg.path, "-mountpoint", mount.path,
                 "-nobrowse", "-noautoopen", "-plist"], seconds: 45)
        let newApp = mount.appendingPathComponent("Flux.app")
        guard let installedID = Bundle(url: installURL)?.bundleIdentifier,
              let candidate = Bundle(url: newApp), candidate.bundleIdentifier == installedID,
              candidate.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              let executable = candidate.executableURL,
              fm.isExecutableFile(atPath: executable.path) else {
            throw Failure.invalidApp
        }
        try run(["/usr/bin/ditto", newApp.path, staged.path], seconds: 120)
        // Extended attributes are outside the code signature. Keep the release
        // signature, bundle identity, and user preferences intact.
        try run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path], seconds: 20)
        try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path], seconds: 30)
        try run(["/usr/bin/hdiutil", "detach", mount.path, "-quiet"], seconds: 15)
        attached = false
        try launchHelper(staged: staged, installURL: installURL, backup: backup, workspace: workspace, executableName: executable.lastPathComponent)
        handedOff = true
    }

    /// Files avoid pipe-buffer deadlocks. The shell gives each command its own
    /// process group so a deadline stops that command and its descendants.
    private static func run(_ command: [String], seconds: TimeInterval) throws {
        let fm = FileManager.default
        let output = fm.temporaryDirectory.appendingPathComponent("flux-process-\(UUID().uuidString)")
        fm.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer {
            try? file.close()
            try? fm.removeItem(at: output)
        }
        let supervisor = """
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
        }
        trap 'stop; exit 124' TERM INT
        deadline=$((SECONDS + limit))
        while kill -0 "$child" 2>/dev/null; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAIL: update command deadline reached: $*"
            stop
            wait "$child" 2>/dev/null
            exit 124
          fi
          sleep 0.1
        done
        wait "$child"
        exit $?
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", supervisor, "flux-update-process", String(Int(seconds))] + command
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        try process.run()
        let deadline = Date().addingTimeInterval(seconds + 5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            Log.menuBar.error("Update process deadline reached: \(command[0]): \(outputTail(output))")
            throw Failure.timeout(URL(fileURLWithPath: command[0]).lastPathComponent)
        }
        guard process.terminationStatus == 0 else {
            Log.menuBar.error("Update process failed: \(command[0]), exit \(process.terminationStatus): \(outputTail(output))")
            if process.terminationStatus == 124 {
                throw Failure.timeout(URL(fileURLWithPath: command[0]).lastPathComponent)
            }
            throw Failure.command(URL(fileURLWithPath: command[0]).lastPathComponent)
        }
    }

    private static func outputTail(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "No process output." }
        defer { try? file.close() }
        do {
            let length = try file.seekToEnd()
            try file.seek(toOffset: length > 4096 ? length - 4096 : 0)
            return String(decoding: try file.read(upToCount: 4096) ?? Data(), as: UTF8.self)
        } catch { return "Couldn't read process output." }
    }

    private static func launchHelper(staged: URL, installURL: URL, backup: URL,
                                     workspace: URL, executableName: String) throws {
        func q(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ready = workspace.appendingPathComponent("ready")
        let helper = workspace.appendingPathComponent("install.sh")
        let log = workspace.appendingPathComponent("install.log")
        let token = workspace.lastPathComponent.replacingOccurrences(of: "flux-update-", with: "")
        let receipt = workspace.appendingPathComponent("startup")
        let executable = installURL.appendingPathComponent("Contents/MacOS/" + executableName)
        let processes = workspace.appendingPathComponent("processes")
        let script = """
        #!/bin/bash
        trap '' HUP
        set -m
        STAGED=\(q(staged.path))
        DEST=\(q(installURL.path))
        BACKUP=\(q(backup.path))
        READY=\(q(ready.path))
        PID=\(pid)
        TOKEN=\(q(token))
        RECEIPT=\(q(receipt.path))
        EXECUTABLE=\(q(executable.path))
        PROCESSES=\(q(processes.path))
        EXIT_WAIT_SECONDS=10
        STARTUP_WAIT_SECONDS=20
        STABILITY_SECONDS=2
        bounded() {
          local seconds=$1
          shift
          "$@" &
          local child=$!
          local deadline=$((SECONDS + seconds))
          while kill -0 "$child" 2>/dev/null; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "FAIL: command deadline reached: $*"
              kill -TERM -- "-$child" 2>/dev/null || true
              sleep 0.2
              kill -KILL -- "-$child" 2>/dev/null || true
              wait "$child" 2>/dev/null
              return 124
            fi
            sleep 0.1
          done
          wait "$child"
        }
        cleanup() {
          local result=$?
          bounded 10 /bin/rm -rf "$STAGED"
          bounded 5 /bin/rm -f "$READY" "$0"
          echo "helper exit=$result"
        }
        trap cleanup EXIT
        : > "$READY" || exit 1
        deadline=$((SECONDS + EXIT_WAIT_SECONDS))
        while kill -0 "$PID" 2>/dev/null; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAIL: Flux is still running; kept the installed app"
            exit 1
          fi
          sleep 0.1
        done
        if ! bounded 10 /bin/mv "$DEST" "$BACKUP"; then
          echo "FAIL: couldn't back up Flux; kept the installed app"
          bounded 15 /usr/bin/open "$DEST"
          exit 1
        fi
        if ! bounded 10 /bin/mv "$STAGED" "$DEST"; then
          echo "FAIL: couldn't replace Flux; restoring the backup"
          if bounded 10 /bin/mv "$BACKUP" "$DEST"; then
            bounded 15 /usr/bin/open "$DEST"
          else
            echo "FAIL: restore failed; old app preserved at $BACKUP"
          fi
          exit 1
        fi
        read_receipt() {
          [ -f "$RECEIPT" ] || return 1
          { IFS= read -r receipt_token; IFS= read -r launched_pid; IFS= read -r launched_path; IFS= read -r phase; } < "$RECEIPT"
          [ "$receipt_token" = "$TOKEN" ] && [ "$launched_path" = "$DEST" ] || return 1
          case "$launched_pid" in ''|*[!0-9]*) return 1;; esac
          [ "$launched_pid" -gt 1 ]
        }
        receipt_process_lives() {
          kill -0 "$launched_pid" 2>/dev/null || return 1
          # A zombie has exited. A failed inspection remains uncertain and
          # therefore keeps the backup rather than permitting replacement.
          bounded 3 /bin/ps -p "$launched_pid" -o stat= > "$PROCESSES" || return 0
          read -r process_state < "$PROCESSES"
          case "$process_state" in Z*|X*) return 1;; esac
          return 0
        }
        startup_ok=false
        if bounded 15 /usr/bin/open -n "$DEST" --args --flux-update-token "$TOKEN" --flux-update-receipt "$RECEIPT"; then
          deadline=$((SECONDS + STARTUP_WAIT_SECONDS))
          stable_since=-1
          while [ "$SECONDS" -lt "$deadline" ]; do
            if read_receipt; then
              receipt_process_lives || break
              if [ "$phase" = ready ]; then
                [ "$stable_since" -ge 0 ] || stable_since=$SECONDS
                if [ "$SECONDS" -ge "$((stable_since + STABILITY_SECONDS))" ]; then startup_ok=true; break; fi
              fi
            fi
            sleep 0.1
          done
        fi
        if [ "$startup_ok" != true ]; then
          # Never kill or replace a live app. An unknown PID or failed scan
          # leaves the old bundle available at BACKUP for safe recovery.
          if read_receipt && receipt_process_lives; then
            echo "FAIL: startup unconfirmed while app lives; old app preserved at $BACKUP"
            exit 1
          fi
          if ! bounded 3 /bin/ps -axo pid=,stat=,comm= > "$PROCESSES"; then
            echo "FAIL: couldn't inspect app processes; old app preserved at $BACKUP"
            exit 1
          fi
          while read -r other_pid other_state other_executable; do
            case "$other_state" in Z*|X*) continue;; esac
            if [ "$other_executable" = "$EXECUTABLE" ] || [ "${other_executable##*/}" = "${EXECUTABLE##*/}" ]; then
              echo "FAIL: live app identity unknown; old app preserved at $BACKUP"
              exit 1
            fi
          done < "$PROCESSES"
          echo "FAIL: update startup failed; restoring the backup"
          if bounded 10 /bin/mv "$DEST" "$STAGED" && bounded 10 /bin/mv "$BACKUP" "$DEST"; then
            bounded 15 /usr/bin/open "$DEST"
          else
            echo "FAIL: restore failed; old app preserved at $BACKUP"
          fi
          exit 1
        fi
        bounded 10 /bin/rm -rf "$BACKUP"
        echo "PASS: installed update and confirmed startup"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let file = try FileHandle(forWritingTo: log)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", helper.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw Failure.helperNotReady
        }
        Log.menuBar.info("Update helper ready; log at \(log.path)")
    }
}
