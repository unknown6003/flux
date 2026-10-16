# Flux layout and performance work

Baseline: `f286253`. Started 2026-10-16.

Outcome: a smaller Settings editor with large icon drag areas, clear section lanes, a visible Move control, reliable native icon moves, measured runtime gains, and a checked release.

Proof: paired baseline/current performance probes; native icon and Settings drag probes; retained-window checks; light and dark Settings snapshots; full self-test; signed release artifact from the reviewed source SHA.

Constraints: macOS 14 minimum; retain native Command-drag and existing saved layouts; no new privacy permission; at most three spaces; publish only after native checks pass. This Linux host has no Swift/AppKit SDK. Native proof must run on the macOS CI runner.

## Ownership

- Parent owns Settings, Settings drag controller, UI probes, CI and release integration in `improve/settings-performance`.
- Performance worker owns IconManager, MacOS27Hider, Services, the paired performance probe and its report in a separate space.
- Research and drag audit agents are read-only. Their artifacts are reviewed before integration.

## Workflow

1. Capture source size and the existing native performance baseline before changing runtime code.
2. Research first-party interfaces, release notes and source. Collect screenshots with source URLs.
3. Use three named section lanes. Make the item body draggable. Keep a visible Move menu and keyboard access. Remove the optional floating grips, global event tap, polling heartbeat and return windows. The independent IconManager keeps native Command-drag.
4. Make only performance changes supported by the paired probe. Keep results that improve measured work and pass correctness checks.
5. Integrate serially. Run native section/order moves, stale identity, cancellation, drag lifecycle, close/reopen, snapshots, resource samples and self-tests.
6. Review the final diff independently. Fix accepted findings and rerun affected checks. Publish the reviewed commit and verify the release DMG source.

The old editor has an 18 by 22 point drag handle and a 30 point drop strip. It shows a synthetic dot preview above a long list. Three gesture systems compete for attention. The replacement keeps the existing section names and amber palette.
