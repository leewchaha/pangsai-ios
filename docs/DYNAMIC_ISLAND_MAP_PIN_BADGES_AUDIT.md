# Dynamic Island POOPING timer / Map avatar badge audit

## Intended behavior

- Starting a timed POOPING session immediately requests **one native ActivityKit Live Activity**.
- The Dynamic Island shows the native elapsed-time timer, including while ShittyFriends is in the background or another app is open.
- The same Live Activity has a Lock Screen presentation and opens the active POOPING screen when tapped.
- The existing **Private lock screen** preference also hides poop imagery and changes the Live Activity label to "SESSION ACTIVE"; toggling it during a session updates the activity.
- Session DONE, Undo or deletion ends the matching Live Activity; relaunch reconciles and removes orphaned activities.
- Activity authorization is optional; if Live Activities are disabled in iOS Settings, the normal poop session still works.
- **No background polling, SceneKit rendering, or continuous animation** is run by the widget. The system timer updates without periodic app wakeups.
- The foreground app creates a small **static PNG snapshot** of its existing faceless 3D poop model and shares it with the widget through the existing App Group. The native timer appears immediately even if the image is not ready.
- A continuously spinning 3D SceneKit model / GIF is **not supported reliably** in a suspended Dynamic Island Live Activity. An image snapshot is the stable platform-compatible alternative. A continuously spinning render has **not** been implemented.

## Map changes

- "just now" is now 13pt offset instead of 24pt, closer to the lower edge of the 3D poop pin.
- Each map cluster shows a 23pt black-bordered badge for the owner of its newest poop, overlaid onto the pin's lower-right edge rather than offset into adjacent map space.
- New Settings > MAP toggle: **Show profile badges on poop pins**, defaults ON. Turning it OFF returns to poop-only pins.
- This version uses the user's **existing generated avatar**. The current profile model does not contain uploaded portrait photos. True photo selection/upload/shared thumbnail syncing is **out of scope** and would need an explicit addition to the identity and CloudKit architecture.

## Code / deployment

- Added XcodeGen target `PoopingLiveActivity` (`com.sakara.shittyfriends.PoopingLiveActivity`).
- App Info.plist includes `NSSupportsLiveActivities = true`.
- Widget extension and app share `PoopingActivityAttributes` and the already configured `group.com.sakara.shittyfriends` App Group.
- Added the third target to the signing-profile preflight and its tests; a new App Store Distribution provisioning profile is REQUIRED for `com.sakara.shittyfriends.PoopingLiveActivity` with App Groups enabled, in Apple Developer portal and Codemagic before a signed TestFlight build can be produced.
- Users with "Live Activities" disabled in iOS Settings will not see the island timer; this is normal.

## Required real-device verification

1. Start POOPING and immediately switch to another app. Timer should display and count upward in the Dynamic Island.
2. Test initial launch with no cached 3D image; activity should still start using the faceless fallback silhouette.
3. Lock the device, then tap the activity; it should reopen the POOPING session.
4. End or Undo the session and confirm its activity disappears.
5. Force-close/relaunch with and without an active session to check orphan cleanup.
6. Deny Live Activities; verify ordinary session logging still works.
7. Check standard, satellite and hybrid map zoom levels, clusters, "just now", badge overlap, map tap gesture.
8. Toggle profile badges off/on in Settings and confirm the state survives relaunch.
9. Test new Codemagic distribution signing on all three targets. This container cannot perform an iOS compiler or runtime test.
