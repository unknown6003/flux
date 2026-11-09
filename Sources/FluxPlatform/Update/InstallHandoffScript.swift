import Foundation

/// Keep the installed updater's started/ready protocol and conservative
/// rollback policy. The new stager also verifies the pinned publisher before
/// this helper is emitted. The helper repeats that check at the final handoff.
enum InstallHandoffScript {
    static func make(staged: URL, installURL: URL, backup: URL, workspace: URL, parentPID: Int32) -> String {
        func q(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let ready = workspace.appendingPathComponent("ready")
        let token = workspace.lastPathComponent.replacingOccurrences(of: "flux-update-", with: "")
        let receipt = workspace.appendingPathComponent("startup")
        let executable = installURL.appendingPathComponent("Contents/MacOS/Flux")
        let processes = workspace.appendingPathComponent("processes")
        let pid = parentPID
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
          local result=$?
          if kill -0 -- "-$child" 2>/dev/null; then
            kill -TERM -- "-$child" 2>/dev/null || true
            sleep 0.2
            kill -KILL -- "-$child" 2>/dev/null || true
          fi
          return "$result"
        }
        cleanup() {
          local result=$?
          bounded 10 /bin/rm -rf "$STAGED"
          bounded 5 /bin/rm -f "$READY" "$0" "${READY%/*}/Flux.dmg"
          bounded 5 /bin/rmdir "${STAGED%/*}" 2>/dev/null || true
          bounded 5 /bin/rmdir "${READY%/*}/volume" 2>/dev/null || true
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
        if ! bounded 30 /usr/bin/codesign --verify --deep --strict -R 'identifier "com.flux.menubar" and certificate leaf = H"A7378EAF65FB4E0A254BAA69167FB772C9DFFBBC"' "$STAGED"; then
          echo "FAIL: staged publisher verification failed; kept the installed app"
          exit 1
        fi
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
          process_inspected=false
          kill -0 "$launched_pid" 2>/dev/null || return 1
          # A zombie has exited. A failed inspection remains uncertain and
          # therefore keeps the backup rather than permitting replacement.
          bounded 3 /bin/ps -p "$launched_pid" -o stat= > "$PROCESSES" || return 0
          process_inspected=true
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
              if [ "$phase" = ready ] && [ "$process_inspected" = true ]; then
                [ "$stable_since" -ge 0 ] || stable_since=$SECONDS
                if [ "$SECONDS" -ge "$((stable_since + STABILITY_SECONDS))" ]; then startup_ok=true; break; fi
              else
                stable_since=-1
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
        return script
    }
}
