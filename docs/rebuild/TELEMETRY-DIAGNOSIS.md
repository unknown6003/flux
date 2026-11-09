# Telemetry wakeup diagnosis

Outcome: explain the observed post-request wakeups before another transport
change. Keep the existing +0.1 interrupt-wakeups/s gate.

Proof: a finite CLI uses the same NativeUsageTransport and PostHogClient as
the app. An external calibrated sampler observes the CLI process after its
request finishes. Phase receipts distinguish a request or retry from later
work. The CLI has no AppKit, preferences, pasteboard or app feature feeds.
Its receipts contain fixed phase names, times, a PID and a fresh test ID.

Constraints: diagnostic-only target, excluded from the app bundle. Its live
modes require FLUX_ALLOW_TELEMETRY_IDLE_PROBE=1 and emit only one fixed marked
launch event per mode. Use a bounded child, preserve the installed app, and
keep all raw profiler output private until reviewed. No grants or UI input.

## Observed red loop

The restored six-run transaction in
`/tmp/flux-analytics-lifetime-20261109-090446` completed at e10b2c0. All three
on/off pairs failed. Extra interrupt wakeups/s were +0.316641, +0.316662 and
+0.349920. CPU, footprint and idle-wakeup gates passed. No pair was rerun.
Parent verification matched 33 archive hashes and recomputed all six runs.

Each on-run added roughly one interrupt wakeup per second until 20–25 seconds
into sampling, then stopped entirely. The three five-second-bin counts were:

| Pair | Consecutive interrupt counts, 12 bins |
| --- | --- |
| 1 | 5, 5, 6, 5, 1, 0, 0, 0, 0, 0, 0, 0 |
| 2 | 5, 5, 5, 5, 2, 0, 0, 0, 0, 0, 0, 0 |
| 3 | 4, 6, 7, 5, 1, 0, 0, 0, 0, 0, 0, 0 |

Restricted backend reads found the three expected launch events with no
profile, IP property or GeoIP fields. Receipt before sampling does not prove
request completion or absence of retries.

The app, signature, full bundle manifest and preferences were restored.
Clipboard bytes changed and changeCount went from 1230 to 1231. The current
clipboard was preserved. The diagnostic made no clipboard write. Saved history
JSON data and Shelf hashes matched; serialization and session state changed.
This is not full restoration equality, a causal transport comparison, or a
full-system performance result.

## Ranked hypotheses and predictions

1. Foundation leaves delayed cleanup after a completed network request. The
   direct transport mode should show the same post-completion wakeup burst.
2. The telemetry client still has a request or retry in progress. The client
   mode should show extra request phases during the burst, unlike direct mode.
3. AppKit or other app work causes the burst. A Core-only CLI should not show
   it while the full app does.

## Run the smaller experiment

Build only the probe with testing access for the existing UsageRequest seam:

```sh
swift build -c release --product FluxTelemetryIdleProbe -Xswiftc -enable-testing
```

Run `FluxTelemetryIdleProbe idle 70`, `direct 70`, and `client 70` under an
outer 120-second deadline and the enable flag. The direct mode sends through
the real transport; client mode queues and flushes through the actual client.
Idle mode constructs neither. Start the separate sampler on quietStarted,
not on process launch. Keep the direct and client objects alive until the end.
The one hold task is the same in each mode; there is no in-process polling.

The builder's one-second idle control checks receipts only. It is not a
performance result. This probe is not a passing app budget or Mac acceptance.

[Raw failed trial](https://templink.bdwy.xyz/media/1794821627-1794908027-10d56c5a166188301b51c0d0.bin).
The link expires on 16 November 2026.
