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

The project is ready for app integration. The native Settings consent control is implemented but is not yet wired to the new executable. No rollout flag, experiment, survey or production dashboard has been activated. The client can encode these fixed-schema uses; that is not a finished user flow. Replay and AppKit interaction autocapture are excluded by the privacy and performance contract. Manual fixed-code exceptions do not prove automatic crash reporting.

Whole-app performance with analytics on and off, signed upgrade acceptance and outgoing content-canary tests remain release gates. The new client is not in the installed0.21.35 app.
