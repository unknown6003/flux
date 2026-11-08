# Media runtime

The rebuilt media reader keeps the pinned BSD adapter. On macOS 15.4 and later,
the adapter loads its Objective-C framework through the system Perl executable.
The existing provenance file records why that process is needed. An ordinary
native helper is not a proven substitute. See
[the pinned source](https://github.com/ungive/mediaremote-adapter/tree/3ac3d4bdf862c7b5399b4fba4df5689f5c38609a).

`MediaDriver` starts that helper only when the app's feature demand asks for
media. It reads event lines from a pipe. It does not poll for elapsed time.
The view can advance its clock only while visible. The app must count the Perl
process and its loaded framework in resource measurements.

The input mailbox holds at most 8 MiB. The parser accepts chunks up to 64 KiB,
one line up to 8 MiB, text fields up to 2,000 characters and one artwork up to
4 MiB. It keeps only the current full/diff state. Repeated artwork keeps the
same local image identity. No track, artist, artwork or source ID enters usage
records or logs.

A first valid frame has an eight-second deadline. Failed helpers get at most
three delayed restarts, at one, three and eight seconds. A stable minute resets
that budget. Stopping cancels readiness and restart work, removes the pipe
callback and terminates the exact child. A child still alive after one second
is killed. Typed commands have a four-second deadline and a four-command cap.
There is no shell command interpolation or inherited Perl injection variable.

The pinned adapter can emit a `playing`-only diff. The parser freezes the
previous clock at the receipt time of that transition. Resume starts from that
point. A scoped independent source review found the original implementation
kept the old clock anchor and counted paused time. A deterministic regression
test now covers pause, resume and a later seek.

Mac CI42526545250 passed the initial parser and fake-process tests at4e868f7.
Those tests prove event parsing, command arguments, command timeout, pending
command completion, child termination and cancellation of a scheduled restart
through a private Perl fixture. The pause fix and feed-release test need their
new CI run. Real playback, artwork memory, source selection, hardware media
controls, rapid panel switches and full process-tree costs remain acceptance
work. This module is not yet connected to a released app.
