# macOS lock-screen reference

Research date: 2026-08-30  
Scope: macOS Sonoma 14, Sequoia 15, Tahoe 26, and Apple's current widget and
Liquid Glass guidance.

## Short answer

The Mac does not have native lock-screen widgets. Apple's Mac guide puts
widgets on the desktop and in Notification Centre. Apple's lock-screen widget
guidance applies to iPhone and iPad. A Flux panel on the Mac lock screen is
therefore a custom overlay, not a Mac widget in the platform sense.

The native Mac lock screen is sparse. The wallpaper fills the display. A small
date sits above a large clock near the top centre. The user image, name, and
password control sit in a compact group near the lower centre. Input, network,
battery, and power controls stay in the top-right status area. The Apple
screenshots do not show a second instruction pill or a widget grid.

For Flux, the closest match is one small centred lock-screen surface for live
media or an urgent activity. It should use a restrained, translucent material,
system typography, and SF Symbols. It should never overlap the password field,
the top-right status area, or the physical notch. A passive part of the overlay
must remain mouse-transparent.

## Apple screenshots

These are first-party screenshots. They are useful for checking placement,
scale, contrast, and the amount of empty wallpaper that the native login UI
leaves visible.

### macOS Sonoma

![Apple's macOS Sonoma login window with the date and large clock at the top, and the user and password field near the bottom centre.](https://cdsassets.apple.com/live/7WUAS350/images/macos/sonoma/macos-sonoma-macbook-pro-startup-login-screen.png)

[Apple Support, "If your Mac doesn't start up all the way"](https://support.apple.com/en-us/102675) identifies this as a macOS Sonoma user login screen. The screenshot shows the large date and time at the top centre, small status controls in the top-right corner, and a small account/password group near the bottom centre.

### macOS Sequoia

![Apple's macOS Sequoia login window with a large clock, centred account controls, and a question-mark password-help control.](https://cdsassets.apple.com/live/7WUAS350/images/macos/sequoia/macos-sequoia-login-window-password-entry.png)

[Apple Support, "If you forgot your Mac login password"](https://support.apple.com/en-us/102633) uses this as the macOS Sequoia login-window example. The password help button is attached to the password field. It is part of the login control, not a separate floating instruction surface.

### macOS Tahoe 26

![Apple's macOS Tahoe 26 lock screen on a MacBook Pro, with the date and large clock above the user account control.](https://www.apple.com/newsroom/images/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/article/Apple-WWDC25-macOS-Tahoe-26-Lock-Screen-250609_big.jpg.large.jpg)

[Apple's Tahoe announcement](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/) calls this the macOS Tahoe lock screen. Apple describes the new Mac design as Liquid Glass and says the lock-screen image keeps the familiar Mac experience. In the supplied image, the lock screen still has one clear vertical reading path: date, clock, account, and authentication prompt.

[Apple's Tahoe feature guide](https://www.apple.com/in/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf) says Tahoe adds six typefaces for the Lock Screen. The typeface is user-configurable, so Flux should use the system font and avoid treating one promotional screenshot's exact clock shape as a fixed font requirement.

## What the native Mac lock screen provides

[Apple's Mac User Guide](https://support.apple.com/guide/mac-help/lock-the-screen-of-your-mac-mchl8e8b6a34/mac) documents these unlock paths:

- Press any key and enter the password.
- Use Touch ID when available.
- Use Apple Watch when configured.

The same guide says that Lock Screen settings control password hints and an
optional message in the login window. It does not describe a widget area or an
app-provided content area.

[The Lock Screen settings reference](https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/26/mac/26) lists the native login controls: user list or name and password, optional Sleep/Restart/Shut Down buttons, password hints, and a message when locked. This is a useful boundary for Flux. The login control owns authentication. Flux should not repeat its prompt or place controls over it.

The same settings page mentions separate battery and power-adapter inactivity
delays. That is a timing setting for display sleep. It is not a lock-screen
widget placement rule.

## Widget constraints from Apple

[Apple's Human Interface Guidelines for widgets](https://developer.apple.com/design/human-interface-guidelines/widgets/) explicitly lists the Mac contexts for system widget families as the desktop and Notification Centre. The Lock Screen context appears for iPhone and iPad, not Mac. This means the Mac lock screen should be treated as a sparse login surface, with Flux's content treated as an opt-in overlay.

The same HIG page gives useful rules for a custom overlay:

- Use the system font and SF Symbols. Apple recommends text at 11 points or larger for glanceable widget text.
- Use 16-point margins for most widgets. An 11-point margin can work for a tight grouping around a control.
- Keep the idea simple and glanceable. Do not turn a widget into an app window.
- Use color to support meaning. Do not rely on color alone, because widgets can become monochrome or tinted.
- Use full-color images with care. Album art is a reasonable exception, but it should stay smaller than the widget itself.
- Keep controls few and relevant. The card can expose play, pause, previous, and next, but it should not grow into a full player window.

[Apple's WidgetKit rendering-mode documentation](https://developer.apple.com/documentation/widgetkit/preparing-widgets-for-additional-contexts-and-appearances) says that Lock Screen widgets use a restrained `vibrant` treatment. The system desaturates text, images, and gauges into a monochrome treatment that adapts to the background. Mac desktop widgets can use accented or full-color treatments instead. Do not copy the full-color desktop treatment into a lock-screen overlay.

[The `vibrant` mode reference](https://developer.apple.com/documentation/widgetkit/widgetrenderingmode/vibrant) states that the system desaturates the widget and uses the result to create an adaptive effect. For Flux, a white or light-gray primary icon and label, plus a quieter secondary label, will read more like the login surface than amber, blue, or saturated brand color. Keep amber for the urgent low-battery meaning only.

## Liquid Glass and material choices

[Apple's Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials) says that Liquid Glass is a functional layer for controls and navigation. It should stay separate from the content layer and should be used sparingly. The page describes two useful variants:

- `regular` blurs and adjusts the luminosity of the background to keep text and controls readable. Apple uses it for components with a meaningful amount of text, including alerts, sidebars, and popovers.
- `clear` is highly translucent and is intended for controls floating over visually rich media. If the background is bright, Apple suggests a dark dimming layer at 35% opacity for contrast.

The current lock-screen media surface has titles, elapsed time, a progress track,
and transport controls. Use the regular material or the closest native standard
material for that card. Use a rounded rectangle with a continuous corner style
for the main card. Reserve a clear surface for a very short activity where the
wallpaper must stay prominent. Do not stack many independent capsules under a
large card. That reads like a custom HUD, not the Mac login surface.

[Apple's Liquid Glass adoption guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) also says to limit custom Liquid Glass effects and let standard SwiftUI, UIKit, and AppKit components provide the normal behavior. Test with reduced-transparency and increased-contrast settings, because those settings can remove or change translucency.

## Visual translation for Flux

These are implementation recommendations inferred from the Apple screenshots
and the platform guidance above. They are not claims that macOS exposes a
public lock-screen widget API.

### Keep the native hierarchy visible

1. Leave the notch silhouette alone. It is a small black hardware shape, not a
   dashboard.
2. Keep the date and large clock unobstructed.
3. Keep status controls at the top right unobstructed.
4. Keep the user image, name, password field, and any native help button
   unobstructed.
5. If live content is present, place one centred card in the open lane between
   the clock and authentication group. Clamp it for short displays so it never
   touches the password control.

The card should disappear when no allowed content exists. A zero-content card
must not leave a transparent, mouse-sensitive window behind.

### Remove the instruction pill

Apple already displays the authentication prompt in the native login group,
such as "Touch ID or Enter Password" or a localized password placeholder. A
second Flux pill saying "Press any key to unlock" repeats that message and
adds another surface below the media card. Remove the pill from the default
layout and remove its setting if the setting has no remaining use. Keep the
native prompt as the only unlock instruction.

### Treat urgent battery as a state, not a new window

The low-battery activity can use the same card lane and the same hit-testing
contract as every other activity. Change the icon and accent to the warning
color, update the percentage in place, and keep the passive surrounding area
mouse-transparent. Do not create a full-screen or full-width warning panel
when the low-battery wing is visible.

## Test plan when the real lock screen cannot be captured

Apple's lock screen blocks normal screenshot capture, so split visual and input
proof into separate deterministic checks.

### Visual proof

- Keep the existing off-screen lock-screen snapshot command and add fixtures
  for no activity, activity-only, media-only, and media plus activity.
- Compare the result against the three first-party references above. Check the
  vertical order, centred alignment, empty wallpaper, card width, corner
  radius, material contrast, and text sizes.
- Render light and dark appearance variants. Also render bright and dark
  wallpaper samples, because clear material can lose contrast on a bright
  image.
- Render a short-height display fixture. The card must clamp above the native
  account/password lane instead of clipping or covering it.

### Input proof

- Test the base silhouette panel and the content card as separate `NSPanel`
  instances. The base panel should ignore mouse events. Only the media
  buttons should accept them.
- Place a sentinel window beneath the overlay in a headless window-server test
  or a small unlocked preview harness. Send a click to the overlay's empty
  area and assert that the sentinel receives it. Send a click to each media
  button and assert that only the media command fires.
- Repeat the input test with the low-battery activity active. This is the
  important regression case. The warning state must not change the base
  panel's mouse behavior.
- Exercise state transitions in a pure test: empty, low battery appears,
  low-battery percentage updates, warning dismisses, media appears, and media
  disappears. After each transition, assert the panel count, frame, and
  `ignoresMouseEvents` values.
- Keep one short manual check on a real Mac after the automated checks: lock
  the screen, type the password, and click the empty area above a window on an
  unlocked desktop after unlocking. This catches window-level mistakes that a
  view snapshot cannot see.

## Source list

- [Apple Support: Lock the screen of your Mac](https://support.apple.com/guide/mac-help/lock-the-screen-of-your-mac-mchl8e8b6a34/mac)
- [Apple Support: Change Lock Screen settings on Mac](https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/26/mac/26)
- [Apple Support: If your Mac doesn't start up all the way](https://support.apple.com/en-us/102675)
- [Apple Support: If you forgot your Mac login password](https://support.apple.com/en-us/102633)
- [Apple Newsroom: macOS Tahoe 26](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/)
- [Apple: New features available with macOS Tahoe](https://www.apple.com/in/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf)
- [Apple Human Interface Guidelines: Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets/)
- [Apple Developer Documentation: Preparing widgets for additional contexts and appearances](https://developer.apple.com/documentation/widgetkit/preparing-widgets-for-additional-contexts-and-appearances)
- [Apple Developer Documentation: `vibrant` widget rendering mode](https://developer.apple.com/documentation/widgetkit/widgetrenderingmode/vibrant)
- [Apple Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple Developer Documentation: Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple Design Resources](https://developer.apple.com/design/resources/)
