# Native shell trial

Choice: Swift6 with AppKit. The small AppKit fixture used less physical memory and had a lower median create/display/release cost than the equivalent SwiftUI fixture. This supports the choice for Flux's explicit view lifetimes and native controls. It does not prove that the new app is faster than0.21.35, or that Swift is faster than every language.

Source14440032b05708fa646ec633824218ea308ed092. [Passed Mac run42505860944](https://github.com/unknown6003/flux/actions/runs/42505860944). Raw data remains in its native-shells artifact and locally at build/native-shell-profile-1444003/samples.json.

Two separate optimized, ad-hoc signed app bundles each present20 rows with a label and a three-choice segmented control. Both use the same AppKit panel and measurement driver. One builds AppKit controls; one uses NSHostingView with SwiftUI content. Three trials alternate their order. Each process samples closed, shown, and closed after20 full view creation/display/release cycles. Each resource interval lasts two seconds. CPU measures process user plus system time; memory uses TASK_VM_INFO. The driver owns no app services or helper process.

| Median of3 trials | AppKit | SwiftUI |
| --- | ---: | ---: |
| Initial closed physical footprint |8.595MiB|8.595MiB|
| Shown physical footprint |27.252MiB|30.330MiB|
| Closed after cycles physical footprint |29.814MiB|33.408MiB|
| Initial closed RSS |37.406MiB|37.641MiB|
| Shown RSS |63.828MiB|67.922MiB|
| Closed after cycles RSS |78.359MiB|83.953MiB|
| Create/display/release cycle |152.309ms|174.515ms|

Footprint ranges across the shown trials were27.080–27.377MiB for AppKit and30.330–30.455MiB for SwiftUI. CPU samples overlap and are too short to establish an idle CPU advantage. No wakeup count, real widgets, media helper, capture, camera, input latency or GPU presentation time was measured. The windows were created on the CI desktop, not through physical user gestures.

The first compile failed because the output name caused the Swift module to be named AppKit. An explicit Flux-prefixed module name fixed it. The next100-cycle run reached its20-second deadline without retained phase logs. That was a failed measurement, not a performance result. The final harness uses app bundles,20 cycles, run-loop callbacks and retained timeout diagnostics. These changes were made together, so the deadline's precise cause was not isolated.

Keep full-app resource gates separate. Test the final signed app with all equivalent features and its helper tree on the real Mac, after warmup and over longer paired intervals.
