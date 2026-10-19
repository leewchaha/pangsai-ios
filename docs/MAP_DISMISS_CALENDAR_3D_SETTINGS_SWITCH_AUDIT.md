# ShittyFriends — map selection, calendar markers, Settings switches

**Date:** 2026-10-08  
**Baseline archive:** ShittyFriends-home-camera-nav-shines-20261008.zip

## Scope

- **Home / Map:** a tap on empty MapKit map space closes the currently selected poop detail card with the existing animation. Tap near another annotation selects that annotation instead of dismissing it. Map scrolling/zoom gestures have not been replaced; MapReader and a simultaneous *tap-only* recognizer are used. Existing close button remains.
- **Calendar:** day cells replace the brown circles with horizontally arranged, faceless `.poop(.classic)` Object3DImage previews, maximum 3. Object3DImage is a cached UIImage from RenderCache, **not** an independent 3D view in each day cell. Days with 4–5 records show `+` after previews; 6+ show `?` after previews. Exact count remains in day details and accessibility.
- **Settings:** an explicit violet tint overrides app-wide near-white dark-mode tint for the native Toggle ON track. OFF track remains system gray. No preference defaults were changed.

## Review / runtime validation checklist (iPhone)

- Select a pin, tap empty map => detail closes; tap another pin => updates; tap same pin => stays; map drag and pinch remain smooth and do not accidentally close just from moving.
- Tap map while the detail card / top filters / Home drawer are visible; their buttons remain responsive.
- Month swipe and date selection still work with markers for 0, 1, 2, 3, 4, 5, 6, and many poops. Confirm readable spacing on compact-width devices.
- On a fresh install, cached 3D image may briefly show neutral render placeholder; confirm it resolves automatically and no emoji face appears.
- Toggle ON/OFF in both light and dark appearance: violet ON track + white thumb; gray OFF track. Confirm VoiceOver correctly announces state and switches remain tappable.

## Automated validation performed

- All Swift sources: `swiftc -frontend -parse` PASS.
- `python -m unittest discover -s scripts/tests -v`: 17 tests PASS.
- `python scripts/verify_appstore_metadata.py`: PASS.
- Info.plist, NotificationService/Info.plist, `project.yml`, `codemagic.yaml` parsing: PASS.
- LinuxCore `swift build`: PASS.
- LinuxCore `swift test`: target compilation reaches link stage, but executable fails due to environment `libswiftObservation.so`/`swift::threading::fatal` linker error. **Tests not executed.**
- iPhone build, SwiftUI/MapKit integration and runtime UI interactions **not tested in this Linux environment**.

## Completeness / scope audit

Expected changes: the three source files above, plus this documentation file. All other original archive entries, including hidden `.git` contents and LinuxCore symlinks, must preserve their payload and metadata. See final verification report in delivery response.
