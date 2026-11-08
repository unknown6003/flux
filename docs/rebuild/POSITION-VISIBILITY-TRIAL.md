# Bounded status-item spacer trial

The current native preference path has not proved physical hiding. A fresh
read of `isAllowed=false` is not enough. The live apply signal remains unknown.
The assessment assertion used by the old app also changes Notification Center
behavior. Do not treat it as a harmless replacement.

[CleanMenuBar's author](https://github.com/atilac/CleanMenuBar) reports that
macOS 27 still hides items behind a spacer just below half the display width.
That is a measured claim by another developer, not a Flux result. Its source
uses the narrowest display width divided by two, minus 20 points. It retains
a separate arrow to the right. A wide display can exceed the method's reach.

`FluxMenuBarLayoutProbe` tests the claim with three temporary status items,
using only public APIs. The right fixture says FX-R, then comes an eight-point
spacer, then FX-L. It saves no autosave names. It posts no input and writes no
application or system preferences. The fixture requires one display and an
existing Screen Recording grant. Its only output is private images and a
fixed receipt in a new, empty, owner-only temporary directory.

The probe requires both fixture labels in the baseline and native frames in
the expected order. It tries three finite collapse and restore cycles. Each
phase waits two seconds. Local Vision recognition records only whether the
two fixture labels were found. It never writes unrelated recognized text.
Every collapse must remove FX-L while retaining FX-R; every restore must show
both. Inspect the images too. An OCR result is not a substitute for that check.
The receipt records exact display, capture coordinates, item frames and times.

The matching-signed bundle has `FluxProbeOnly` and `FluxLayoutProbeOnly` flags.
It cannot launch the product delegate, storage, analytics or feature services.
Run only with `FLUX_ALLOW_MENU_LAYOUT_PROBE=1`, the one private output directory
argument, and an outer 90-second deadline. Normal exit removes all three items.
Process death also removes the process-owned status items. The operator must
restore the original Flux bundle and process after any installed-path trial.

The old Flux assertion may affect the observation. A real trial must record
whether old Flux is running, and test without that assertion after a normal
quit and a settled wait. Preserve its preferences and restore the same signed
app. There is no reason to change grants, existing icon order, the clipboard,
or any native app's visibility flag.

Passing this fixture would establish one hiding primitive on one Mac. It would
not prove group assignment, Always Hidden, multiple displays, Spaces, notch
overflow, relaunch, the new app's user flow or release reliability.
