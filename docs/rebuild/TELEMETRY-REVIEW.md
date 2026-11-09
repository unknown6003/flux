# Telemetry review

> Later change: anonymous collection is now always on, with no Settings switch or reset control. See TELEMETRY.md. Consent and on/off wording below is historical.

Independent Standards, Spec and Risk contexts reviewed4efe32fe1d01547fca6e212e06e26dbfa1e95c03 against2d81d9dd0549324dbfef3bf8da2aa68665e84229. All16 changed files were in scope. The parent checked each finding against source. No production app or live account was claimed.

## Standards

No documented-rule breach. Two optional duplication findings: repeated flag JSON parsing and separate fixed-window admission counters. Keep the two counters because one avoids UI task creation and one protects direct actor callers. Parsing is bounded at64KiB; combine the two decoder passes during a later small cleanup if this path becomes material. The stale PLAN status was corrected.

## Spec

No confirmed defect in the stated intermediate unit. The final user request is not complete. Whole-app wiring, custom survey presentation, automatic crash coverage, live project/privacy settings, full request canaries and paired performance remain open. Boolean flags were missing; they now preserve Boolean values in evaluation, exposure and conversion records. Holdout behavior needs its own scope and server proof before claiming it works.

## Risk

Two source-confirmed failures were fixed at0f4b0c4a19d0ff8deac2c0595dcc4f5e331494f5:

- A background flag reload replaced the variant on later conversions even though the UI had used the previous variant. Choices and payloads now stay stable after first use until ID reset or process restart. Conversions carry the used assignment. The regression test changes compact to guided behind a visible compact experience and checks the conversion stays compact.
- Events always had priority, so steady events could starve logs. Sends now alternate when both queues contain records. The regression test keeps replenishing events and checks the second batch sends logs.

[Mac run42504865424](https://github.com/unknown6003/flux/actions/runs/42504865424) passed all20 tests, including both regressions. The parent also inspected the small post-review delta. The source traces established the old failure paths; a separate executed red control was not run. Live ingestion, server privacy and full-app overhead remain unverified.
