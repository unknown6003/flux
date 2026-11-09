# PostHog contract

Status: the Swift 6 client, transport and opt-in controller are implemented. The Flux EU project is configured. A live native probe, rating acknowledgement and server readback passed at64c1fcf. The old installed app has no new telemetry integration. See POSTHOG-PROJECT.md for evidence and limits.

## Data

Product code can submit only `UsageEvent` values. The types have no arbitrary strings or property dictionaries. Allowed data is feature names, action names, result codes and fixed failure codes. Each batch adds event UUIDs, timestamps, a random resettable usage ID, and explicit no-profile and no-GeoIP properties. The project token selects the ingestion project.

The ID is independent of an account, hardware, device identifiers and the operating-system user. It still links events from that installation. Resetting it cannot remove data already sent. Do not call linked records unlinkable or promise server deletion from a local reset.

Never add automatic collection of app names or bundle IDs, track or event names, clipboard text, file names or paths, URLs, window titles, keystrokes, screen images, camera frames, raw errors or arbitrary logs. Diagnostics copied by the user are a separate local flow.

## Native capabilities

The official SDK's current macOS implementation supports event analytics, flags and experiments, and manual error and log reporting. The source audit found that replay is iOS-only, surveys exclude macOS, and interaction capture uses UIKit. Verify the final supported list against pinned primary source before implementation. Reports, funnels and retention are server-side uses of the same safe events, not new collection permissions.

A default SDK installation is insufficient for this contract. Its event filter does not filter flag requests or all log resource fields. Its timers also run for unused queues. Any SDK or direct API implementation must pass the same final-request tests.

## Verification gates

1. Inspect every outgoing request type, including config, flags, events, errors and logs. Use a fake collector and content canaries. Check the complete serialized request and headers.
2. Verify server IP discard and disabled GeoIP with the actual project's settings and ingested records. A client property alone does not prove server policy. The server still sees a network connection unless a relay removes the source address.
3. Verify no client, task, timer, file or request exists when analytics is off. Disable during a delayed request, clear queued records, and confirm no later retry. Reset during a pending batch and ensure that batch cannot reintroduce the old ID.
4. Verify fixed queue and response-size limits, backpressure, request timeout, cancellation, retry caps and offline loss behavior.
5. Measure on/off resource and user-action costs with identical workloads. Record uncertainty. Do not claim zero overhead from a passing compile or an idle screenshot.

## Project access

The owner account and restricted maintenance key are in the shared credential store. The public ingestion token and EU region are configured in FluxUsageProject. The private maintenance key and account password are excluded from the app and repository.

## Chosen client

Use the native public HTTP contracts, without the SDK. It has a serial actor, an ephemeral URLSession with no cookies, cache or credential store, one active request, fixed hosts, refused redirects, five-second request and eight-second resource timeouts. Response decoding stops at 64 KiB. There are at most 64 queued events and 32 queued logs. Each send takes at most 20 records. Rate limits apply before the UI controller creates asynchronous work and again at the actor.

The first three empty-profile on/off pairs at 283d50c failed the wakeup
budget in pair three: +0.11665 interrupt wakeups per second. Other measured
budgets passed. Network settling was not measured, so the source of those
wakeups is unresolved. The transport retained its session between requests.
It now creates an ephemeral session only for a send and invalidates it on
every exit. This removes idle connection ownership; a native lifecycle check
and a new paired measurement are required before claiming a cost reduction.

A one-shot flush task exists only while records wait. Empty and disabled clients have no periodic flush. Retryable failures get at most three attempts with bounded delays. There is no telemetry disk spool. Offline records can be lost; preserving every usage event does not outrank app memory and privacy.

Missing consent keys default to off on both new and upgraded profiles. Only an explicit saved opt-in starts the client. Disabling cancels the pending task and request, drops records and clears cached assignments. A request already received by the server cannot be recalled. Reset drops pending work, clears flags/exposures, and changes the random ID. Late UI submissions carrying the previous local ID are rejected.

The encoders support usage events, presentation flags, experiment exposures/conversions, fixed-code manual exceptions, structured code-only logs and fixed rating survey events. A deliberate About rating sheet is bound to the acknowledged submission path. No native crash handler, recorder, AppKit autocapture or automatic survey presentation is installed. Flags and experiments have no active product rollout.

ApplicationHost routes its existing failure callback through the opt-in collector
before calling the local reporter. The exhaustive mapping accepts only typed
ApplicationFailure cases. Settings save, login, clipboard, recovery, timer and
link failures have fixed codes; runtime and widget failures share the coarse
serviceUnavailable code. It reads no error object, title, URL, item or payload.
The off path still invokes the local reporter without constructing a client.
Native CI 42561810305 at 283d50c completed both host checks. The enabled
check entered ApplicationHost.report, used the real collector and encoder,
and captured the exact fixed exception properties through a fake transport.
The disabled host still reported locally and retained the rejecting client
factory. These checks use no real network. The 680-point light and dark
General fixtures show the ID explanation without clipped controls.

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
