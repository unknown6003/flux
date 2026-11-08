# PostHog contract

Status: core encoding only. Nothing is installed, configured or sending data.

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

No PostHog entry exists in the shared credential store. A project token and the correct region are needed for live integration. Project-admin access may be needed to verify IP and GeoIP settings and to configure flags, experiments and reports. Never put a personal API key in the app.
