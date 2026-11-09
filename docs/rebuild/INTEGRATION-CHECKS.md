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
including idempotent cleanup and the coordinator action controls. The later
quiet automatic fallback control is awaiting the next run.
The app coordinator adopts a user check into an in-flight background check,
and drops late responses after stop. An unwritable destination currently
opens the release page from a manual install action. It does not implement
the previous cached DMG in Downloads flow yet.

## Remaining product gates

The new executable entry and complete SettingsEffects owner are not written.
Menu-bar physical hiding and its live apply signal are not accepted. No
assessment-mode fallback is accepted: upstream documents that assessment mode
can block Notification Center, so that side effect must not be hidden from
acceptance. Guided native ordering replaces synthetic drags in the design.
Lock-screen presentation, Duo content and late widget content sizing still
need integration. Opus's latest UI continuation hit its provider rate limit;
no substitute UI model ran. The whole signed app, migration, hardware use,
resource comparison and clean action media remain release gates. No release
has been made.
