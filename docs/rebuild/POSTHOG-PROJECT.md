# Flux PostHog project

Configured8 November2026 under the owner's verified email account. Project Flux, ID340600, EU region. Dashboard: https://eu.posthog.com/project/340600.

The account password is in global credential entry `posthog-flux-login`. The project-restricted maintenance key is in `posthog-flux`. Only the public ingestion token is in app source. No payment method, paid upgrade or organization-wide API grant was added.

## Verified server settings

A fresh authenticated read confirmed IP storage disabled, web autocapture disabled, session recording disabled and the GeoIP transformation disabled. Disabling the existing GeoIP transformation changed only its enabled field. Network infrastructure still receives the connection's source address. Random usage IDs link records until reset. This is content-free, pseudonymous telemetry, not a proof of unlinkability.

## Native transport and server proof

Mac CI run42513701564 at22fcc49 passed41 core tests and the real native client probe. Flags, event batching and OTLP logs each received HTTP200. The probe sends only fixed synthetic records marked `flux_validation=true`. It requires the explicit `FLUX_ALLOW_POSTHOG_PROBE=1` guard and is off in normal CI.

Authenticated HogQL readback found exactly the two expected events, `flux_feature_opened` and `$exception`, for the probe's random ID. Both had `$process_person_profile=false`, `$geoip_disable=true` and the validation marker. Neither contained an IP or GeoIP location field. The person API returned zero profiles. PostHog added exception grouping fields, which proves server error processing. The Logs viewer showed one Flux `serviceStarted` record at19:11:51.019 UTC. No user content was used.

Raw evidence is ignored under `build/native-posthog-22fcc49/`: transport.json, server-readback.json and project-privacy.json. CI: https://github.com/unknown6003/flux/actions/runs/42513701564.

## Open gates

The native candidate binds the Settings consent control to UsageCollection. No rollout flag, experiment or production dashboard has been activated. A fixed manual rating survey is prepared as a draft; its native entry and fake-transport acknowledgement flow passed four AppKit scenarios. Live rating readback remains open. The client can encode these fixed-schema uses; that is not a finished user flow. Replay and AppKit interaction autocapture are excluded by the privacy and performance contract. Manual fixed-code exceptions do not prove automatic crash reporting.

Whole-app performance with analytics on and off, signed upgrade acceptance and outgoing content-canary tests remain release gates. The new client is not in the installed0.21.35 app.

## Manual native rating

A project-restricted API call created the draft API survey Flux native rating,
survey ID 01a1be49-73be-0000-0847-40b0937bb5da, with one number rating from
1 to 5. Question ID 3318e47e-87af-444d-9a1d-4e7cd3a8c58b. Its start date
remains null. There is no automatic display or free-text question. No response
was submitted during setup. Public identifiers are in FluxRatingSurvey.

The explicit submission path uses a stable event and submission UUID for
retries. It accepts only the fixed UsageRating enum and requires saved consent.
A UI acknowledgement requires HTTP 200 with the documented batch status
"Ok" or legacy numeric status 1, and no reported quota suppression. It rejects late replies after reset or opt-out and observes
caller cancellation. This is ingestion acknowledgement, not proof that a
server query has processed the event. Native controls and the fake acknowledgement path passed CI42559152812.
Live rating readback remains required. A canceled or failed request may already have reached the server.

References: https://posthog.com/docs/api/surveys,
https://posthog.com/docs/surveys/implementing-custom-surveys and
https://posthog.com/docs/api. The custom-survey contract requires string
ratings, which the existing encoder already uses.

The public rating API uses an opaque `UsageRatingSubmission`. Create it with
`UsageCollection.makeRatingSubmission(_ rating:)`, then await
`UsageCollection.submitRating(_:)`. One token binds one rating and the current
random identity. Retries reuse it. Core rejects it after an identity reset,
before network admission. The UI cannot read or replace its identifiers.

Live probe CI42559974776 returned HTTP200 for all four requests, but the new
rating acknowledgement check rejected the15-byte batch reply. The official
API overview documents status "Ok". Core now accepts that exact value plus
legacy numeric1, rejects false/error/string-number forms, and retains quota
suppression checks. The failed run is not a rating-delivery pass. The next
live run and server readback must prove the corrected contract.
