# Native integration checks

The installed app remains 0.21.35 build 62. This file records component checks,
not release acceptance.

## Widget bindings

A scoped source review at dd8a9cd found three defects. The parent checked each
path and fixed them in a29c048.

| Trigger | Change | Native check |
| --- | --- | --- |
| A copy resumes after lock or widget dismissal | Each visible widget gets a revocable write authorization. PasteboardChannel checks it inside the synchronous commit, after actor waits. Closing or releasing the owner revokes it. | closedWidgetCannotWriteThroughAQueuedPasteboardAction uses a private pasteboard and checks that a stale authorization cannot change its count or contents. |
| Artwork changes while ImageIO is decoding | One decode runs at a time. One pending request keeps only the latest image. Hide drops that request and rejects the old result. | artworkCoalescesWhileDecodeRunsAndDropsWorkOnDismiss holds a decoder, sends 30 replacements, and verifies that only the latest runs next. |
| Remove is pressed on a copying Shelf row | Pending copies are skipped. A running copy is removed from the owned shelf when it finishes. Originals are left alone. | removingRunningAndPendingCopiesLeavesOnlyOriginalFiles runs the batch against a real temporary ShelfFiles store with a held copy. |

These checks passed on the Mac in CI42532122840. That run failed a separate
panel lifetime test, so the run as a whole did not pass. The tests do not
establish real lock notification timing, camera shutdown or large cloud-file
copy behavior. The three review findings were source findings, not native
reproductions of the old application.

## Notch window

The AppKit window owner was integrated from Opus commit 58e8901 as 91307ab.
Its test drives a real NSPanel, switches and dismisses widgets, and checks the
stop-before-removal order. An immediate weak-reference check retained the
old child. A later synchronous run-loop wait also blocked other main-actor
test work. At 79573ed the test yielded the main actor. Child release then
passed, but the real panel reopened Mirror after collapse and lock. A late
viewDidAppear called show after dismiss had cleared current. Dismissal is
now final for that panel instance. The added regression calls the late
appearance method and checks that it cannot create another widget. The
fixed native tests passed in CI42533115317 and CI42533925638.

A separate source review found that repeated start on an unchanged screen
replaced the owner's widget list but left the panel's list unchanged. Start
now calls setWidgets. The panel test disables Mirror through that actual
repeat-start path and expects Shelf to replace it before collapse.

## Capture calibration

The finite status-item fixture stopped at a black baseline on the user Mac.
Its own items had valid AppKit frames. No hide/show cycle ran. A new
--calibrate mode creates one owned, click-through window labeled FLUX-CAL.
It compares an individual-window capture with two global-coordinate and two
display-filter candidates. It creates no status items and posts no input.
This tests capture coordinates and access before another visibility trial.
The own-window control and both top-coordinate candidates showed FLUX-CAL;
the bottom-coordinate candidates did not. This establishes the top-coordinate
mapping for that control. It does not establish third-party capture access.

A later Launch Services trial returned the installed Flux process rather than
the explicit diagnostic. The diagnostic inherited the product's
LSMultipleInstancesProhibited=true flag. The diagnostic builder now sets this
flag to false before signing. The product flag stays true. The later journaled launch returned the exact diagnostic path and a separate
PID, then failed its Screen Recording preflight. See the receipt below.

## Startup

The new ApplicationSession keeps the existing updater's started/ready receipt
format, inspects old data before creating new files, and takes a nonblocking
single-writer lease. The lock descriptor closes on process death and uses close-on-exec.
A copied descriptor can still exist between fork and exec. Explicit unlock
now ends the owner lease before the descriptor closes. It rejects symlink and hard-linked lease files.
Analytics starts after ready and only for an existing opt-in. No feature is
started by constructing this session. This is not yet the executable entry.

## Runtime and activities

NotchRuntime now connects the session phase, feature demand, real widget feeds
and window owner. It stops private feeds before removing the visible widget.
The lock-screen factory remains a required outer dependency. This
is application wiring, not an executable or a release candidate.

A separate risk review found a Mirror retry race: the old driver's delayed
stop cleared a preview layer after the new feed attached it. CameraFeed now
detaches that layer synchronously before scheduling driver shutdown. A native
regression reuses one real preview layer between two session objects without
camera input. The runtime and camera regression passed in CI42535635588.

ActivityCoordinator binds the eight activity kinds and countdowns to local
events. Producer ticks update an existing queue entry without restoring a
user dismissal. Timer completion keeps its ten-second alert when another
timer starts. Calendar deadlines cover the ten-minute threshold and event
start; text refreshes only for a presented activity. Artwork uses the bounded
pipeline. CI42536314946 passed 69 Core, 19 Platform, 9 UI and 12 Application
tests, including the real ten-second timer restoration test. Overflow reports
now keep a dismissal until the current overflow episode ends.

CI42534958255 passed 68 Core, 18 Platform, 9 UI and 5 Application tests at
fa0fefc. That run includes publisher rejection tests and the corrected signed
diagnostic builder. The diagnostic now launches through Launch Services as a
distinct process, but its output directory stayed empty. No physical hiding
result follows from that launch check.

The instrumented Launch Services test at 23:46:35 UTC returned
screenCaptureNotAllowed before taking an image. Its receipt recorded the
expected six arguments and allow flag. The diagnostic exited and original
Flux stayed running. This identifies that launch's permission gate; it does
not establish the complete app's permission state. Further capture trials
are deferred until the signed executable is ready.

## Accessory notifications

DeviceDriver uses IOKit matching notifications and the Core Audio device-list
listener. The old app also used these notifications; the new implementation
does not establish a measured speed improvement. CI42536658372 passed 71 Core,
20 Platform, 9 UI and 12 Application tests, including real read-only listener
creation and release. Actual accessory connect/disconnect flows remain untested.

A separate review found that cached match and termination iterators could be
drained in the wrong order, leaving a terminated service present. Notifications
now only trigger a fresh active-registry snapshot. Apple's current XNU source
routes getMatchingServices through copyExistingServices with MatchedState;
instanceMatch also excludes InactiveState. Termination clears MatchedState.
See [IOService.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOService.cpp).
This is source evidence, not a runtime disconnect result on the user's kernel.

The other review finding was an initial failed audio read treated as empty.
AccessoryInventory now keeps source validity separate. It cannot publish a
complete baseline until both sources are known. A failed later read preserves
the last source value. The nil-to-known baseline regression passed in CI42537382772.
Names remain a local deduplication aid: equal names can merge distinct devices,
and different names from the two OS sources can still duplicate one device.


## Current compiled integration

CI42539763718 at03a4fc5 passed73 Core,28 Platform,9 UI and15 Application tests.
It also rendered66 interface fixtures. The run compiles the new download and
staging actors. The bounded command process checks, per-key mute capability,
key-queue overflow, event-consumption dispatch, writer-lease copied-descriptor
regression and late clock/grant notifications are included. No test posted a
real key, changed the user's volume, mounted a release image or installed an
app. The copied-descriptor regression failed first in CI42538060228; the
original intermittent lease failure's precise cause remains unknown.

NotchSubsystem now joins the activity router, feature demand and real window
owner. AppShortcuts retains old registrations after a refused replacement.
Its scoped independent source review found no defect. Carbon hardware input,
real accessory changes and full-screen/display transitions remain unproved.

## Update preparation and recovery

ReleaseDownload uses a serial utility delegate, bounded response and byte
counts, incremental SHA256 and a private output file. Its native URLProtocol
controls test an exact download, excess and short bodies, a bad digest,
existing-file protection and cancellation cleanup. No network is used by
these controls. Release redirects are restricted to HTTPS GitHub release
hosts. The signed bundle verifier still pins Flux's existing publisher.

UpdateStager prepares a private copy beside the destination before the old
app quits, verifies it after copying, and verifies it again before handoff.
The helper keeps the installed four-line started/ready receipt and conservative
rollback policy. Eleven local synthetic helper cases pass, including parent
still running, swap failure, relaunch failure and hang, early crashes, live
unconfirmed startup, failed process inspection, a child outliving its command,
and final signature rejection. These exercise filesystem and process control,
not a genuine signed upgrade through Launch Services.

The scoped update risk review found two recovery faults. Final signature
rejection now reopens the original app. Discard now tolerates an already
removed stage directory, rather than retaining a permanently busy token.
CI42540130699 atc8590cf passed73 Core,29 Platform,9 UI and17 Application tests,
including idempotent cleanup and the coordinator action controls. The quiet automatic fallback control passed in CI42541924774.
The app coordinator adopts a user check into an in-flight background check,
and drops late responses after stop. An unwritable destination now prepares a verified manual DMG in a private
Downloads folder. A quiet automatic check does not open it. An explicit
Install action opens the verified file. Cache reuse checks its complete
hash; changed or missing files cannot reuse that result. The native controls
passed in CI 42544306921 and CI 42545438106. Actual signed mounting and
installation remain untested.

## Remaining product gates

ApplicationHost implements the SettingsEffects owner and passes a native
off-feature composition check. The new executable entry and concrete menu
bar and lock-screen services remain to be completed.
Menu-bar physical hiding and its live apply signal are not accepted. No
assessment-mode fallback is accepted: upstream documents that assessment mode
can block Notification Center, so that side effect must not be hidden from
acceptance. Guided native ordering replaces synthetic drags in the design.
Lock-screen presentation remains open. Duo feed binding and lifecycle
controls pass. The 77 rendered fixtures exposed collapsed real-widget
content after the scroll-cap fix, so layout acceptance remains open. No substitute UI model ran. The whole signed app, migration, hardware use,
resource comparison and clean action media remain release gates. No release
has been made.

## Host and shelf retention

CI42541924774 at9709dba passed73 Core,29 Platform,9 UI and19 Application
checks. ApplicationHost has required menu and lock-screen protocols, routes
private content only to local consumers, and completes teardown before the
clean-session marker. The off-feature host test uses its own defaults suite
and files. Its external services are fakes, so it does not accept those
production backends. A source risk review found an initial overflow value
published before the notch started and a license link with no bundled file.
Startup order now preserves the value; packaging copies the license into the
named path. The full packaged application still needs verification.

CI42542583680 ata9aab7a adds a passing saved shelf-expiry control, for20
Application checks. It proves the old owned copy is removed while the source
and recent copy survive. A host profile with notch off and positive saved
expiry creates no shelf files. Expiry has no repeating idle task.

## Native preference trace limit

The native dictionary setter encodes a plist and writes through an
NSUserDefaults key path. Its immediate method is setTrackedApplications:,
which calls setObject:forKey: withtrackedApplications. The shared controller
receivesgroup.com.apple.controlcenter. Foundation posts a defaults-change
notification on its immediate write path. These static facts identify no
cross-process observer or live hide operation.

A fresh own-process comparison returned nil for both public suite reads and
CFData of6620 bytes for both explicit-container reads. The two CF values
matched in bytes and structure. The public suite therefore did not supply
the container value in that process. No setter, input, grant or app-state
change was performed. Private Mac reports are retained at
/tmp/flux-receiver-construction-2026-11-09.md and
/tmp/flux-suite-comparison-20261109/report.md. They do not accept live hiding.

## Latest native and visual check

CI 42545438106 at 593579d passed 73 Core, 30 Platform, 11 UI and
24 Application cases. The tall-widget window-cap test now passes and reaches
the bottom of the document by scrolling. The rendered Duo fixtures show only
the tab strip, however. The real widget viewport must also remain visible.
Commit 69ce5fa adds that control with actual Now Playing and Calendar views.

Eight lock-content fixtures rendered. The dark card, caption and transport
controls are readable. The empty fixture has no content. This proves neither
a lock-screen window nor click-through to password entry. The private space
bridge remains absent. Installed arm64 disassembly uses 64-bit space IDs;
Int32 declarations are unsafe for that inspected path. Creation failure,
array formats and ordered cleanup still need proof.

Two read-only Mac traces also found no basis for a production preference
signal change. The registry subscribes to objectWillChange and rereads the
allow flag. A downstream loop changes stored bytes and calls more work, but
its physical window effect is not resolved. Native and explicit CF setters
use different source lookup routes and both reach a shared lower-level
source setter and local observer loop. The native local defaults notification
does not prove cross-process delivery. The reports remain private at
/tmp/flux-abi-501/report.md and
/tmp/flux-defaults-setter-trace-20261109.md on the Mac.

## Drag lifecycle and manual feedback checkpoint

CI 42554890966 at 10a353e passed 73 Core, 45 Platform, 11 UI and 43
Application cases. New AppKit destination controls cover drag cancellation,
periodic readiness updates, full-screen collection flags and one owned shelf
copy job. These controls call actual destination methods with private test
pasteboards. They do not prove Finder event delivery or behavior on a real
full-screen Space.

CI 42555424135 at e4851c1 passed 78 Core, 45 Platform, 11 UI and 43
Application cases, plus the signed candidate build. The manual feedback path
requires an ingestion acknowledgement and rejects quota suppression. Opt-out,
caller cancellation and identity reset cannot return a late accepted result.
The follow-up cb661b2 binds a retry token to one rating and one random identity.
Its added reset control is awaiting native CI. The native rating form is not
bound yet. The project survey remains a draft, with no automatic display.

The signed real-app trial reached a local authentication prompt for Screen
Recording. The tester canceled it and restored 0.21.35. The original and
candidate have the same designated signing requirement, but the OS grant is
still off. Physical menu-bar observation and hiding remain blocked on that
local grant. No update was released.
