# Menu bar identity review

Outcome: an app that no longer satisfies its saved signing requirement needs
review before Flux accepts another group change. Keep the saved group through
ordinary updates and an approved identity change.

Proof: the Menu Bar owner tests exercise first enrollment, a matching update,
decline, approval, replacement during review, page exit and malformed storage.
A native signed process checks actual Security requirement evaluation. The
AppKit probe drives the real confirmation buttons and task cancellation.
CI 42589502622 at e10b2c0 passed 79 Core, 46 Platform, 11 UI and
50 Application tests, plus four rating scenarios and the composite identity
sheet control. The latter checked Cancel, approval and task cancellation.
AppKit resets default shortcuts while presenting NSAlert, so Flux sets Cancel
as the default after presentation and the control checks the actual default
button cell. The saved sheet bitmap was black and was rejected as visual proof.
These are component checks, not an interactive Mac or hiding acceptance result.

## Check and storage

MenuBarIdentityReader runs on its own actor. It obtains a dynamic code object
from the process ID, checks the sealed signing identifier against the app ID,
copies its designated requirement and validates the running code against it.
If a saved requirement exists, macOS evaluates the running code against that
requirement. Comparing requirement bytes would reject valid updates, so it is
not used for continuity. Validation forbids network access. No signing data
enters telemetry.

The first valid observation is enrolled locally. This preserves existing
visibility choices without asking the user to approve every installed app.
The versioned flux.menuBar.identities.v1 preference holds at most 256 app IDs
and requirements of at most 16 KiB each. Writes keep unknown top-level fields.
Invalid or newer storage is preserved and leaves hiding paused.

A requirement mismatch is distinct from missing or invalid signature evidence.
Only a mismatch offers Review. A missing check cannot approve a copy. This is
identity continuity, not a Gatekeeper, notarization or malware verdict. Ad-hoc
code may need review after a rebuild because it has no stable signer identity.

## Apply and lifetime

The position backend stays paused until a complete inventory has valid identity
evidence. It pauses during refresh and on app launch or exit, then checks again.
There is no idle polling. The unverified backend still performs no startup
inventory; its editor scan remains explicit.

Review opens a native sheet with Cancel as the Return-key action. Approval
requires a click. After that click, Flux checks the app again and verifies that
the stored old pin and the presented new requirement have not changed. It saves
only the identity pin and rereads the inventory. It does not move an icon or
change the saved visibility choice.

Leaving the page or stopping cancels the review. A late result cannot write.
Security calls are synchronous inside the actor and have no caller-supplied
IPC deadline. Cancellation is checked between calls; stop discards the read
without waiting for a call to return. A slow Security call must not block quit
or the UI. This limit needs a native cost measurement before release.

This adds no proof that the public spacer physically hides an icon. The backend
remains unverified by default. Continuous pixel visibility and the private
macOS allowance path are separate acceptance gates.

## Primary references

[Apple dynamic validation contract](https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/SecCode.h)
describes running-code validity and requirement evaluation.
[Apple requirement storage contract](https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/SecRequirement.h)
defines the supported binary round trip.
[Apple validation flags](https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/CSCommon.h)
document no-network validation on dynamic code from macOS 11.3.
