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
flag to false before signing. The product flag stays true. A fresh launch with
an exact returned-path and PID check is still required.

## Startup

The new ApplicationSession keeps the existing updater's started/ready receipt
format, inspects old data before creating new files, and takes a nonblocking
single-writer lease. The lock descriptor closes on process death and is not
inherited by helpers. It rejects symlink and hard-linked lease files.
Analytics starts after ready and only for an existing opt-in. No feature is
started by constructing this session. This is not yet the executable entry.

## Runtime and activities

NotchRuntime now connects the session phase, feature demand, real widget feeds
and window owner. It stops private feeds before removing the visible widget.
The device and lock-screen factories remain required outer dependencies. This
is application wiring, not an executable or a release candidate.

A separate risk review found a Mirror retry race: the old driver's delayed
stop cleared a preview layer after the new feed attached it. CameraFeed now
detaches that layer synchronously before scheduling driver shutdown. A native
regression connects two real preview layers without camera input. Runtime and
camera regression results are pending.

ActivityCoordinator binds the eight activity kinds and countdowns to local
events. Producer ticks update an existing queue entry without restoring a
user dismissal. Timer completion keeps its ten-second alert when another
timer starts. Calendar deadlines cover the ten-minute threshold and event
start; text refreshes only for a presented activity. Artwork uses the bounded
pipeline. Tests for dismissed battery, timer and calendar events are pending.

CI42534958255 passed 68 Core, 18 Platform, 9 UI and 5 Application tests at
fa0fefc. That run includes publisher rejection tests and the corrected signed
diagnostic builder. The diagnostic now launches through Launch Services as a
distinct process, but its output directory stayed empty. No physical hiding
result follows from that launch check.
