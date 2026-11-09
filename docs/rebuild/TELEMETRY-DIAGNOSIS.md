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
swift build -c release --product FluxTelemetryIdleProbe -Xswiftc -enable-testing -Xswiftc -DFLUX_TELEMETRY_IDLE_DIAGNOSTIC
```

Run `FluxTelemetryIdleProbe idle 70`, `direct 70`, and `client 70` under an
outer 120-second deadline and the enable flag. The direct mode sends through
the real transport; client mode queues and flushes through the actual client.
Idle mode constructs neither. Start the separate sampler on quietStarted,
not on process launch. Keep the direct and client objects alive until the end.
The one hold task is the same in each mode; there is no in-process polling.

The builder's one-second idle control checks receipts only. It is not a
performance result. This probe is not a passing app budget or Mac acceptance.
Normal builds compile a disabled stub, so the diagnostic's test access cannot
break a plain Release build or enable a diagnostic by an environment flag alone.
CI 42594259193 at 17778bf passed both the plain Release disabled control and
the explicitly enabled Release build and one-second idle receipt control.
The Mac experiment uses the equivalent enabled probe from 8d2235f. Neither
build control is a passing app performance result.

[Raw failed trial](https://templink.bdwy.xyz/media/1794821627-1794908027-10d56c5a166188301b51c0d0.bin).
The link expires on 16 November 2026.

## Isolated result at 8d2235f

One idle, one direct-transport and one client run completed on macOS 27.0.1.
Interrupt wakeups over the 60-second quiet sample were 1, 42 and 37. Each live
mode completed exactly one HTTP 200 request before quietStarted, with no later
request start. Both bursts ended around 40 seconds after completion. Parent
verification matched all 48 archive hashes and recomputed the wakeup totals.
Restricted backend readback found the three marked launch events from the two
primary modes and the separate profile, with no person profile, IP property
or GeoIP fields.

AppKit and the full app are not required for this reproduction. Neither are
extra requests or a retained PostHogClient. This narrows the boundary to the
native transport/network path. It does not identify a particular timer or
prove delayed Foundation cleanup. A separate 20-second sample mostly showed
blocked threads; one sparse active stack was on com.apple.network.connections.
That sample cannot establish the cause. Its overhead is excluded from metrics.

The installed app and clipboard were not accessed. All owned diagnostic,
sampler and profiler processes exited. These are diagnostic observations,
not an app budget pass or a variance estimate.

[Isolated receipts, metrics and profile](https://templink.bdwy.xyz/media/1794822654-1794909054-41c7e25c53f307aaf07a51b9.bin).
The link expires on 16 November 2026.

## Next boundary comparison

A diagnostic-only C shim now sends the same fixed marked launch body with the
system libcurl easy API. The existing direct mode still uses the production
Foundation transport. Idle, direct and curl run in the same probe binary with
the same hold and sampler. The live modes must complete successfully before
sampling. The shim has a fixed HTTPS EU endpoint, peer/host verification,
no redirects, 5-second connection and 8-second transfer limits, and a 64 KiB
response cap. It runs on a utility worker. No app transport is replaced.

Prediction: if the new engine avoids the post-completion burst while direct
reproduces it in the same build, that supports a transport-driver alternative.
It does not identify the old timer or accept a production replacement. The
shim is intentionally single-transfer and diagnostic-only. Production global
lifetime, cancellation, headers, proxies, error paths and all endpoint contracts
would need their own native proof before promotion.

Primary contracts: [blocking easy transfer](https://curl.se/libcurl/c/curl_easy_perform.html),
[bounded write callback](https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html),
[transfer timeout](https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html), and
[allowed protocols](https://curl.se/libcurl/c/CURLOPT_PROTOCOLS_STR.html).


## Engine comparison, 9 November 2026

Root verified all 44 manifest hashes and the three raw counter differences.
Archive SHA-256 is
`91906ad3d47f7022f25d16ea87f89b5ff0e49a17b71ed427b098f067695f654a`.
One 60-second sample per mode observed idle 1, Foundation 44 and curl 1
interrupt wakeups. Both requests completed HTTP 200 before sampling and no
later request started. Root restricted server readback found both marked
launch events, no person profiles and no stored IP or geolocation fields.
This supports trying a different HTTP engine. It does not estimate variance,
identify the Foundation wakeup cause or pass the app's performance budget.

[Raw source, receipts and samples](https://templink.bdwy.xyz/media/1794823644-1794910044-878d4acf3b9c24c30dcaea6f.bin).

## Production transport change contract

Outcome: keep the existing consent, typed payloads, rate limits, retries and
identity rules, while replacing Foundation HTTP with a bounded libcurl driver.
Proof: real loopback TLS tests through NativeUsageTransport, existing client
and identity tests, restricted live ingestion readback, then three unchanged
signed-app analytics on/off pairs. Product acceptance is separate.
Constraints: HTTPS fixed EU/US ingestion routes only; verified certificate and
hostname; no redirects, cookies, netrc or disk queue; 64 KiB request and response
caps; 16 KiB cumulative accepted response headers; 5-second connect and
8-second transfer limits; one admitted request per transport; explicit atomic
cancellation; no UI or cooperative executor blocking. The C driver uses one
process-lifetime global initialization and per-request easy-handle cleanup.

The system library must be at least curl 7.85 and expose thread-safe global
initialization, asynchronous DNS and TLS. Runtime feature checks follow the
one-time initialization, under the supported system-library assumption.
macOS 14 runtime compatibility still needs verification before release.
Cancellation is cooperative during the finite request, so an already submitted
request can reach the server before cancellation takes effect. Reset and disable
still reject late application results through the existing generation guards.

Proxy environment settings use curl's standard routing. This does not yet prove
parity with macOS system proxy or PAC settings. Flux does not inspect or log proxy environment values itself. Libcurl may
consume credentials included in a configured proxy URL. The header cap limits bytes accepted by our callback;
libcurl can buffer an individual header internally before delivering it.

The old Foundation implementation now lives only in the isolated diagnostic.
Direct mode preserves that historical comparison; client mode uses the new
production transport. The raw curl prototype remains diagnostic-only.

Primary contracts: [thread safety](https://curl.se/libcurl/c/threadsafe.html),
[cancellation](https://curl.se/libcurl/c/CURLOPT_XFERINFOFUNCTION.html),
[TLS peer checks](https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html),
[proxy routing](https://curl.se/libcurl/c/CURLOPT_PROXY.html), and
[fixture connection mapping](https://curl.se/libcurl/c/CURLOPT_CONNECT_TO.html).


Source reviews of `6de2f5c..3164012` covered Standards, Spec and Risk in three
separate contexts. No blocking finding survived primary source checks. The
Standards heuristic about numeric C result codes was accepted and the Swift
switch now uses named constants. The proxy paragraph was clarified because
libcurl can consume credentials from proxy environment URLs. A primary follow-up
also makes Swift task cancellation take precedence over a simultaneous result
copy error. Native tests and real performance remain required.


## Final native check and next app measurement

[CI 42599206633](https://github.com/unknown6003/flux/actions/runs/42599206633)
passed at source `2f9c9598f2f2693b341622259b0df0f63f525463`: 86 Core,
46 Platform, 11 UI and 50 Application tests, four rating scenarios and one
identity confirmation scenario, updater controls and a matching-signed
0.22.0 build 64 candidate. The local TLS tests include pre-cancelled work,
active cancellation, recovery, trust/hostname refusal, redirects, all routes,
response caps and timeout. Restricted fresh server readback confirmed the
three synthetic events including the acknowledged rating, no person profiles
and no stored IP/geolocation fields. Initial reads returned no events; later
fresh blocking reads confirmed ingestion. HTTP 200 alone was not counted as
ingestion proof.

Candidate ZIP SHA-256 is
`7ed7198f11be24b69aa429567750a0394c496aafb592bf0cf6e609874168937e`,
1,807,677 bytes. Its executable SHA-256 is
`0e3fda115787b08434f1f072f48c439f85c740d7f6c239178e740344ef4a564f`.
The uploaded copy was downloaded and matched. The next signed-app trial uses
that exact artifact, unchanged 45-second warmups, six 60-second samples and
the original per-pair budgets. It must restore the installed app and saved
state without overwriting concurrent user changes. It is running, not passed.
Physical hiding, normal workloads, action latency and release acceptance remain
open. No update was published.


## Curl app trial failed one pair

The six-run trial of source 2f9c959 completed with unchanged 45-second warmups
and 60-second samples. Extra interrupt rates were -0.000018, +0.016663 and
+0.166647/s. Pair three failed the +0.1/s limit. CPU, mean and peak footprint
and idle wakeups passed every pair. Root matched all 37 evidence hashes and
recomputed all six raw runs. Restricted readback found three expected launch
events, no person profiles and no stored IP/geolocation fields.

Pair-three on-run interrupt bins were `0,0,0,1,1,0,0,0,0,10,2,0`. The
large burst was at 45 to 55 seconds of sampling, unlike the earlier long
Foundation burst at the start. A server receipt before sampling does not
prove request completion or absence of retries. The cause remains unknown.

Restoration passed the original bundle manifest, executable, strict signature,
version, exact URL and one process; all preferences including absences; and
clipboard decoded data, serialization and changeCount. Shelf hashes and saved
history JSON matched. History serialization and session fields changed, so
state-file byte equality was not claimed.

[Trial source, samples and restore receipts](https://templink.bdwy.xyz/media/1794826267-1794912667-e2625c508f529a46c73e9783.bin).
Archive SHA-256 is
`9b68cc811b47ca0f0b77fc1947bb67818d557e35569f6c77ff5252fb8edea66a`.

### Next diagnostic contract

Outcome: distinguish delayed work in the production curl driver from work in
the telemetry client and the rest of the app. Do not change production HTTP
again without a measured cause. Proof: idle, native-transport and client modes
in one isolated CLI, explicit request phases, a fixed 15-second delay after
completion, then 13 observations over 60 seconds. A historical Foundation
direct mode is a positive control for the already observed burst. Hold each
process for 90 seconds after quietStarted. No app swap or saved data access.
Run native and client three times each, plus one idle and one historical
Foundation positive control, in fixed order idle/native/client/direct/native/
client/native/client. This gives eight runs without selective retries. The
sample delay matches the approximate time from the launch batch to the app
sample; it is a new diagnostic, not a rerun or replacement budget result.
Three quiet repeats do not disprove an intermittent source.

Ranked predictions before testing:

1. Retained curl runtime work causes the late burst. A single request through
   the production NativeUsageTransport should reproduce it without the app
   or PostHogClient. The old raw prototype used per-request global cleanup,
   so its quiet result did not test this production lifetime.
2. Client scheduling causes the late burst. Client mode should add work or a
   request after its first completion while native mode stays quiet.
3. An app or system event causes the late burst. Both isolated production
   modes should stay quiet. That would direct the next trace to full-app
   lifecycle notifications, not prove a particular event or invalidate the
   failed pair.

The existing performance feedback loop needs a full 60-second interval to
observe this late, intermittent burst. A seconds-long pass cannot substitute
for it. This diagnostic narrows that loop while preserving the relevant
post-completion timing. No production feature behavior changes in this slice.
