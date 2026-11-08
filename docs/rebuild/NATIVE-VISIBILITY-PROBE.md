# Native visibility diagnostic

This is a diagnostic, not the rebuilt Flux app. It is not installed. It does not alter physical icon order. Its private ABI was checked on macOS27.0.1. Physical hide/show acceptance is still open.

The CLI prepares a private journal before a write. The journal contains the target app, its original Boolean, its location identity and executable aliases. Each write reads fresh preferences, checks target ownership and changes only the target Boolean. The Core tests cover duplicates, aliases, malformed schemas, changed identity and fresh unrelated edits. The private preference API still replaces the complete data value. It has no compare-and-swap operation, so an external write during that narrow interval remains a release risk.

The Python supervisor owns every write subprocess. It is detached from the process that starts it. It accepts one request at a time, limits each command, kills a stalled command before restoring, and restores on expiry, finish, SIGTERM or SIGINT. Cleanup tries restore at most three times. Eight fixture tests include timeout, partial failure, termination, transient recovery and a persistent failure report. Those tests do not prove the macOS preference API. Killing the supervisor itself with SIGKILL or powering off defeats this diagnostic guard. Do not use it as a production crash-recovery system.

Create a new canonical, owned0700 directory. Use an owned regular0600 journal. Substitute exact absolute paths below. All commands need an outer deadline. Keep raw app inventory and captures private.

```sh
FluxVisibilityProbe prepare com.tunabellysoftware.tgpro /ABS/PRIVATE/journal.json /Applications/TG\ Pro.app/Contents/MacOS/TG\ Pro
python3 visibility_guard.py start --probe /ABS/FluxVisibilityProbe --journal /ABS/PRIVATE/journal.json --seconds 180
python3 visibility_guard.py send --journal /ABS/PRIVATE/journal.json hide
python3 visibility_guard.py send --journal /ABS/PRIVATE/journal.json restore
python3 visibility_guard.py send --journal /ABS/PRIVATE/journal.json finish
```

Check ready.json before any hide. Record its exact PID and guard.log. The guard lasts at most240 seconds plus one bounded action, three bounded restore attempts and half a second between attempts. A request takes at most70 seconds. If a request fails, stop sending actions, read finished.json and make a fresh independent allowed-value check. A successful finish response is followed by finished.json with restored=true. Verify that file before ending the test. The direct emergency restore is `FluxVisibilityProbe restore /ABS/PRIVATE/journal.json`, also with a deadline.

For physical proof, use the separate matching-signed capture probe in one recorded fixed screen region. Require readable baseline glyphs, then three true/false/true cycles. Check system controls and capture every transition. Do not infer visibility from a Boolean or an AX placeholder. Quit only old Flux during the controlled experiment to remove its assessment policy, then restore it. Compare saved preferences and clipboard without publishing their contents. If the physical baseline is unreadable or an alias is ambiguous, perform no write.
