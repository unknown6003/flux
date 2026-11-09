# Analytics idle pairs, 9 November 2026

Historical Foundation result: **FAIL** at source `283d50c734e9d4115d23a9df258d0c6d2d3d7bd4`.
Pair three exceeded the interrupt wakeup budget. The mean does not pass a
failed pair. All CPU, physical-footprint and idle-wakeup pairs passed.

Each run used the same signed 0.22.0 build 64 candidate, an empty profile,
a 45-second warmup and 13 observations over 60 seconds. Orders were off/on,
on/off, off/on. The running profiles differed only in the analytics switch.
A new controlled random ID replaced the saved ID for the trial.

| Pair | CPU extra, % of one core | Footprint extra, MiB | Interrupt extra, /s | Idle extra, /s |
| --- | ---: | ---: | ---: | ---: |
| 1 | -0.001445 | +0.707956 | -0.016663 | -0.016663 |
| 2 | +0.016513 | +0.941129 | +0.049982 | 0 |
| 3 | +0.013339 | +0.421898 | +0.116652 | +0.016664 |
| Limit | +0.1 | +5 | +0.1 | +0.1 |

Parent verification matched all 31 archive hashes and independently recomputed
all six CSV runs and the three pair differences. The CPU-unit calibration
matched getrusage within 0.001%. Each run observed one attributed process.
Five pre-existing PPID-1 helpers were excluded and left alone. RSS was also
recorded but has no separate budget and can double-count shared pages.

A restricted server readback found the three expected `flux_launched` events
for the controlled test ID. It found no person profile, IP property or GeoIP
fields. A later parent query of `created_at` placed server receipt 12.596,
12.653 and 13.021 seconds before the corresponding on-sample starts. This
establishes receipt before sampling, not request completion or absence of
retries, connection activity or other network work during a sample.
[PostHog defines these event times](https://posthog.com/docs/data/events).

The original 0.21.35 build 62 app, signature, full bundle manifest, preferences
and one exact-URL process were restored. Pasteboard item bytes and changeCount
matched. Shelf hashes and saved clipboard JSON content matched. Clipboard
property-list and history serialization bytes changed; session state and
timestamps also changed. The trial did not overwrite user content to force
byte equality.

The retained URLSession is one source hypothesis, not a proved cause. The next
Foundation candidate created a session only when sending and invalidated it
on every exit. Source review found no retained defect, but the fresh three-pair
measurement below failed. The original budget remains unchanged.

This empty-profile trial does not accept hiding, active features, user-action
latency, full-system performance or release readiness.

[Sanitized source and raw samples](https://templink.bdwy.xyz/media/1794818768-1794905168-b49d59a2cbeea67fcf746beb.bin).
The link expires on 16 November 2026. Keep its contents as historical evidence;
it is not the new candidate's result.

## Second trial after session cleanup

The e10b2c0 candidate completed three new pairs, again with 45-second warmups
and 13 observations over 60 seconds. All three interrupt-wakeup comparisons
failed: +0.316641, +0.316662 and +0.349920/s. CPU, physical footprint and idle
wakeups passed. This later campaign does not isolate the cause of the difference
from the first one. Parent verification matched 33 archive hashes and recomputed
all six raw sample metrics.

The burst is concentrated in the first 20–25 seconds of sampling and then ends.
The transport change did not pass its intended budget. Do not increase the
warmup, select a quiet tail or relax the limit to turn it into a pass. The following direct-transport/client/idle experiment reproduced the burst in
Foundation. A later narrow curl comparison supported a driver alternative.
See TELEMETRY-DIAGNOSIS.md for its limits and the bounded production change.
The new curl-backed signed app still needs the same three-pair budget test.

The original app and full preferences were restored. Clipboard bytes changed
and changeCount rose from 1230 to 1231. Current content was preserved. Saved
clipboard-history JSON data and Shelf hashes matched; serialization and session
state changed. Thus this trial did not pass full clipboard restoration equality.

[Second trial, source and restore receipts](https://templink.bdwy.xyz/media/1794821627-1794908027-10d56c5a166188301b51c0d0.bin).
The link expires on 16 November 2026.
