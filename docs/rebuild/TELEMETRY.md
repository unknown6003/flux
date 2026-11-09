# PostHog contract

Status: the Swift 6 client, transport and always-on controller are implemented. Anonymous collection is on for every profile and has no Settings switch. The Flux EU project is configured. Live native probes, rating acknowledgements and restricted server readbacks passed, including the final curl transport source at 2f9c959. The old installed app has no new telemetry integration. See POSTHOG-PROJECT.md for evidence and limits.

## Data

Product code can submit only `UsageEvent` values. The types have no arbitrary strings or property dictionaries. Allowed data is feature names, action names, result codes and fixed failure codes. Each batch adds event UUIDs, timestamps, a random usage ID, and explicit no-profile and no-GeoIP properties. The project token selects the ingestion project.

The ID is independent of an account, hardware, device identifiers and the operating-system user. It still links events from that installation. Settings has no reset control. Do not call linked records unlinkable or promise server deletion.

Never add automatic collection of app names or bundle IDs, track or event names, clipboard text, file names or paths, URLs, window titles, keystrokes, screen images, camera frames, raw errors or arbitrary logs. Diagnostics copied by the user are a separate local flow.

## Native capabilities

The official SDK's current macOS implementation supports event analytics, flags and experiments, and manual error and log reporting. The source audit found that replay is iOS-only, surveys exclude macOS, and interaction capture uses UIKit. Verify the final supported list against pinned primary source before implementation. Reports, funnels and retention are server-side uses of the same safe events, not new collection permissions.

A default SDK installation is insufficient for this contract. Its event filter does not filter flag requests or all log resource fields. Its timers also run for unused queues. Any SDK or direct API implementation must pass the same final-request tests.

## Verification gates

1. Inspect every outgoing request type, including config, flags, events, errors and logs. Use a fake collector and content canaries. Check the complete serialized request and headers.
2. Verify server IP discard and disabled GeoIP with the actual project's settings and ingested records. A client property alone does not prove server policy. The server still sees a network connection unless a relay removes the source address.
3. Verify no client, task, timer, file or request exists before `UsageCollection.start()`. The client's own `disable()` and `resetIdentity(_:)` paths keep their tests: disable during a delayed request clears queued records with no later retry, and a reset during a pending batch cannot bring back the old ID.
4. Verify fixed queue and response-size limits, backpressure, request timeout, cancellation, retry caps and offline loss behavior.
5. Measure on/off resource and user-action costs with identical workloads. Record uncertainty. Do not claim zero overhead from a passing compile or an idle screenshot.

## Project access

The owner account and restricted maintenance key are in the shared credential store. The public ingestion token and EU region are configured in FluxUsageProject. The private maintenance key and account password are excluded from the app and repository.

## Chosen client

Use the native public HTTP contracts, without the SDK. The client is a serial actor. A small C libcurl driver runs on a utility queue, with one active transfer, fixed HTTPS hosts, verified TLS, refused redirects, five-second connect and eight-second transfer timeouts. Each transfer uses a fresh handle with no cookies or netrc. Request and response bodies stop at 64 KiB; accepted response headers stop at 16 KiB. Atomic cancellation aborts transfer callbacks, and Swift rejects canceled results. Libcurl is initialized once for the process; per-request cleanup never tears down shared global state. There are at most 64 queued events and 32 queued logs. Each send takes at most 20 records. Rate limits apply before the UI controller creates asynchronous work and again at the actor.

The first three empty-profile on/off pairs at 283d50c failed the wakeup
budget in pair three: +0.11665 interrupt wakeups per second. Other measured
budgets passed. Network settling was not measured, so the source of those
wakeups is unresolved. The transport retained its session between requests.
The next candidate created an ephemeral session only for a send and invalidated
it on every exit. Native Core checks at b480a59 passed the real URLSession lifecycle
fixture, including lazy creation and invalidation after three successful sends
and an oversized response. Source review found no retained issue. These checks
prove cleanup in those cases, not a resource saving. A new paired measurement
was run at e10b2c0 and failed all three interrupt-wakeup comparisons, with
extra rates of +0.316641, +0.316662 and +0.349920 per second. No cost reduction
is claimed. The source of the wakes remains unresolved. A Core-only probe distinguished network completion, retries and work from the app.
A later one-run-per-engine comparison observed idle 1, Foundation 44 and curl 1
interrupt wakeups over 60 seconds each. That supported the bounded curl change;
it did not estimate variance or pass the signed app budget. Native TLS tests
cover all routes, trust and hostname rejection, redirects, caps, cancellation
and timeout. The production curl app trial then failed pair three at +0.166647 interrupt
wakeups/s. The other two pairs and every CPU, footprint and idle-wakeup
comparison passed. A repeated driver-only/client diagnostic with explicit
request timing is now running. No app performance pass is claimed.
See ANALYTICS-PAIR.md and TELEMETRY-DIAGNOSIS.md.

A one-shot flush task exists only while records wait. Empty and disabled clients have no periodic flush. Retryable failures get at most three attempts with bounded delays. There is no telemetry disk spool. Offline records can be lost; preserving every usage event does not outrank app memory and privacy.

Collection is always on. `UsageCollection.start()` builds the client for new and upgraded profiles after the app is ready. It ignores the old opt-in key `flux.analytics.enabled.v1`, so a saved `false` from an earlier build does not stop events. Settings has no analytics switch, reset control or notice; the data stays anonymous and the source code shows every field. Nothing is built or sent before `start()`. Tests: `eventsSendEvenWhenTheOldOptInWasSavedAsFalse`, `startCollectsOnANewProfileAndKeepsOneIdentity` and `nothingIsBuiltOrWrittenBeforeStart` in `Tests/FluxCoreTests/UsageCollectionTests.swift`.

The encoders support usage events, presentation flags, experiment exposures/conversions, fixed-code manual exceptions, structured code-only logs and fixed rating survey events. A deliberate About rating sheet is bound to the acknowledged submission path. No native crash handler, recorder, AppKit autocapture or automatic survey presentation is installed. Flags and experiments have no active product rollout.

ApplicationHost routes its existing failure callback through the collector
before calling the local reporter. The exhaustive mapping accepts only typed
ApplicationFailure cases. Settings save, login, clipboard, recovery, timer and
link failures have fixed codes; runtime and widget failures share the coarse
serviceUnavailable code. It reads no error object, title, URL, item or payload.
Before `start()`, the host still invokes the local reporter without constructing a client.
Native CI 42561810305 at 283d50c completed both host checks. The enabled
check entered ApplicationHost.report, used the real collector and encoder,
and captured the exact fixed exception properties through a fake transport.
The disabled host still reported locally and retained the rejecting client
factory. These checks use no real network. Those runs predate always-on collection;
the enabled check now calls `start()` instead of a saved opt-in.

## Proposed release budgets

These are gates, not measured results. Use three paired 60-second runs after warmup, with the same feature state and helper tree. Keep the raw samples and variance. Baseline activity must be known before claiming idle results.

| Measure | Limit for analytics on versus off |
| --- | --- |
| Closed and empty | No analytics request or scheduled flush task |
| Physical footprint after warmup | At most 5 MiB extra |
| CPU over the paired interval | At most 0.1% of one core extra, with uncertainty reported |
| Wakeups | At most 0.1 per second extra; unavailable counters leave the gate unverified |
| Synchronous record call, p95 | At most 0.1 ms, measured on the real Mac |
| Reveal and notch action latency, p95 | At most 1 ms extra, with paired variance reported |
| Stalled network stress | 1,000 actions finish independently; queues and retries stay within their caps |

If a metric exceeds the limit, fix or reduce the integration. Do not round a small cost to zero.
