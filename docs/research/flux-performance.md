# Flux performance checks

Outcome: reduce repeat AX work and repeat state updates without changing icon moves or features.

Proof: run `Scripts/probe_performance.py` against the fixed baseline and the candidate on the same Mac. Use the native behavioral probes for correctness.

Constraints: keep native icon move timing, saved layouts and privacy access intact. Native checks run on the disposable macOS CI desktop. The parallel release thread owns drop spacing and the Hider's background access diagnostic callback. Integration stays serial.

## Native CI evidence

The paired runtime check passed on macOS 27.0.1 arm64 at `ce3d377` in [run 38847975225](https://github.com/unknown6003/flux/actions/runs/38847975225). The raw result is retained in `flux-performance-first-pair.json`.

- Thirty controlled failed-clock lookups made thirty AX-boundary attempts in the baseline and one in the candidate, in all three alternating rounds. The fixture injects a 2 ms delay. This proves 97% fewer attempts during that burst, not a whole-app speedup. Expiry retries and successful cache reads also passed.
- One hundred unchanged denied-access refreshes published inventory, trust and error one hundred times each in the baseline and zero times in the candidate. Both retained two hundred busy-state publications. Stale inventory still clears on denial.
- One hundred unchanged denied Calendar refreshes published one hundred times in the baseline and zero times in the candidate.
- The first native inventory scan ran with an empty inventory. Its small timing difference does not establish a useful scan speedup. The current fixture launches twelve real status items and requires both builds to read all twelve.

[Run 38849139917](https://github.com/unknown6003/flux/actions/runs/38849139917) completed both alternating full-app resource rounds at `0104341`, including fifty Settings open, General, Menu Bar and close cycles per round. The candidate retained its hosting controller in all one hundred cycles. The baseline replaced it in all one hundred. CPU and RSS samples cover the main process only. The tab timing gate in that version checked window readiness but did not prove the requested content had rendered. Those tab timings must not be used as a latency claim.

The current full-app probe adds the same native rendered-tab marker to both temporary source builds. It requires the requested tab's visible, completed layout and a display flush. A deliberately skipped General navigation must fail this gate after ten seconds. This proof and the twelve-icon workload must pass before final numbers are reported.

Hardware feature loads, real media playback, helper-process costs, GPU presentation, long sessions and slow third-party AX servers remain outside these measurements. The source still has a 150 ms timed native Command-drag sequence. It needs separate tracing before its timing can change.

## Baseline capture

The baseline is `f286253671eae213e7d8f419aea2cb4b6210049b`. Before changing production code, the worker ran:

```sh
python3 Scripts/probe_performance.py --prepare-only --output build/performance/before-edits
```

Its `results.json` records identical baseline and candidate source hashes. This fixes the inputs for a later paired run. It is not a runtime baseline. No Flux runtime numbers were captured by this worker.

The worker runs Linux x86_64 with Python 3.13.5. Swift and AppKit are absent. The connected Mac reports Darwin arm64, but T3 exposes no shell tool for it. A bounded SSH attempt returned `ssh: connect to host 100.77.158.72 port 22: Connection refused`.

The native command was attempted after the edits. It exited with status 2 and wrote `blocked: native Swift/AppKit measurements require macOS` to `build/performance/current-attempt/results.json`. That is a blocked check, not a pass.

## Findings and edits

`MenuBarIconManager.refresh()` assigned the same trust flag, empty inventory, and access error on each denied refresh. Successful scans also assigned an unchanged inventory. These `@Published` writes can trigger view and subscriber work. Equality guards now skip these writes. The AX element map still refreshes on every successful scan. Update start and end signals still fire.

`CalendarService.refresh()` also published an unchanged empty or fetched event list. It now checks equality first. Permission revocation still clears events and resets the store latch. Event fetches and refresh triggers are unchanged.

`MacOS27Hider.clockFrame()` cached successful reads for two seconds. A failed read left no cache entry, so mouse movement could cause repeated AX scans. The cache now stores a failed result for the same two-second window. The existing near-clock fallback still runs when the frame is unknown. A clock that becomes readable during that window can take up to two seconds to be found.

The clipboard fallback uses a 200 ms timer with 50 ms tolerance. Its old comment said 2.9 Hz and 150 ms tolerance. The comment now matches the code. The timer rate and capture logic are unchanged because reducing the rate could miss copies.

## Costs left for native tracing

- `MenuBarIconManager.drag()` blocks its main actor with 60 ms plus five 18 ms sleeps on macOS 27. The 150 ms is the sum of explicit waits in source, not a measured UI stall. Changing event timing needs real move and overlap checks.
- `MacOS27Hider.scanPositions()` uses synchronous `concurrentPerform`. It reads each icon's position and size over AX. The caller waits for all replies. Each app gets a 200 ms messaging timeout. The actual pause needs a Mac trace with slow or unresponsive apps.
- Inventory scans repeat per-app AX reads when layout settles and when moves are verified. They also scan Live Activity children. Sharing these reads could change freshness and move validation. No cross-scan cache was added.
- Clipboard history polls while enabled so it can catch producers outside Command-C and Command-X. Most other Services use events or a single deadline task. The active helper process, camera capture, Calendar fetch, image work, and feature UI still need resource samples.

These findings come from source inspection. They are not CPU, memory, wakeup, or latency measurements.

## Paired benchmark

Run this on a logged-in Mac with Xcode command-line tools. On a disposable GitHub macOS desktop, the native scan reuses the existing temporary AX grant helper and restores its prior grant after the probe exits.

```sh
python3 Scripts/probe_performance.py --baseline-ref f286253 --repeats 3 --native-scan --output build/performance/paired
```

The script reads the exact baseline sources with `git show`. It copies current sources without changing a checkout. Both copies use the same optimized Swift fixture and compiler flags. Runs alternate baseline and candidate order. The report keeps all samples, per-round totals, median, p95, maximum, publication counts, source hashes, OS, and compiler version. Build time is outside the fixture timings.

The fixture exercises the public denied-access inventory refresh and Calendar refresh paths. It subscribes to their real Combine publishers. It checks that denial clears seeded stale data and that later denials still clear changed data. Candidate gates require zero duplicate inventory, trust, error, and denied Calendar publications. Busy start and end publications must remain intact. A Mac that already grants Calendar access reports the denied Calendar case as unavailable.

The clock workload calls the production clock lookup through a private accessor appended only to temporary source copies. A fault before the AX call waits 2 ms and returns no frame. Both builds get the same fault. This measures cache attempts and the cost of a controlled failure burst. It does not measure native AX latency. The candidate must make one attempt during the burst and retry after cache expiry. A seeded successful cache must still return its frame.

The optional native scan times ten real inventory refreshes per round. It requires a desktop and AX access. Missing access is recorded as unavailable. The script does not post input or apply hiding. Native scan times depend on the running apps and icons, so keep that desktop stable.

## Resource samples and behavioral run

Use the same optimized app build, display layout, settings, icon set, and feature state for baseline and candidate. Record a quiet 30-second sample after launch settles. Pass the exact Flux PID. The sampler records its executable path and checks process start time to detect PID reuse.

```sh
python3 Scripts/probe_performance.py --pid "$FLUX_PID" --sample-only --seconds 30 --sample-label idle --output build/performance/idle
```

CPU is the process CPU-time delta divided by measured wall time, expressed as percent of one core. RSS is in KiB. Both exclude helper processes and GPU work. Sample the MediaRemote helper separately if it is running. macOS `top` idle-wakeup output is kept raw when supported. It is a separate one-second sample and does not count all timer fires. Missing wakeup data stays unavailable.

Repeat the sample with Settings open, after same-tab reopen, while using the drawer, and during native drag. Also sample each enabled feature in use. Use separate output folders and `--sample-label` values. A label records the stated workload. It does not prove that the workload occurred.

Run the existing native behavioral checks on a disposable GitHub desktop:

```sh
python3 Scripts/probe_performance.py --baseline-ref f286253 --repeats 3 --native-scan --suite --output build/performance/full
```

This adds Settings close and reopen, saved-layout drawer response, layout scans, native drag, and Live Activity checks. Each command has a deadline and a process-group stop path. The suite records whole-command elapsed time, including builds. That value is not window, scan, hide, reveal, or drag latency. An absent Live Activity is unavailable, not a pass. The drawer probe's existing `DRAWER_MS` values measure the synchronous saved-layout toggle call, not the time until the screen changes.

The parent must also run the normal native build, self-test, icon movement and overlap probes before release. This worker did not change CI or release metadata.

## What this worker verified

- The pre-edit source record matches the exact baseline.
- Python compilation, CLI help, source preparation for both Swift fixtures, and summary statistics pass.
- The process sampler works against this Python worker on Linux. That is a script check, not Flux resource data.
- A short forced timeout stops the probe command group.
- `git diff --check` passes.

These were the worker's checks at handoff. The native CI runs above supersede its original runtime blocker. Final-source native checks, the twelve-icon resource run, rendered-tab timings and the signed release artifact are still required. No app-wide speedup or perfect-reliability claim follows from the controlled publication and clock results.
