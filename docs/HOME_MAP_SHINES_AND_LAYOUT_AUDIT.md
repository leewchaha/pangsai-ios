# Home Camera, Navigation Clearance & Pin Shines — 2026-10-08

## Intent

- All four main tabs use the **measured actual floating navigation height** plus a 12-point gap, instead of assuming the bar is 100 points tall. Home's activity drawer, selected-location card, empty-state card, and Undo button use that shared reserved viewport; the map image itself may draw under the navigation.
- Home's `MapCameraPosition` lives in `MainShell` so switching tabs does not recreate `.automatic` camera state. First available poop locations seed one explicit camera. CloudKit updates and map style changes do not refit an existing camera. `Map(position:)`'s own gesture binding tracks subsequent pan/zoom; no `onMapCameraChange` feedback loop is added.
- Selected pins lose the opaque stroked circle and gain **one animating SwiftUI shine behind the existing centered faceless 3D model**. Unselected pins create no shine views and run no effect animations. Respect Reduce Motion.
- Pin-shine variants: Classic White (free), Golden (800 PTS), Electric (1,700), Neon Orbit (3,500), Aurora (6,000), Prismatic (10,000). Different rays, bolts, and line-orbit designs. Pin shine is cosmetic, not a new map location or real-world light effect.
- `Me → Collection` contains a separate Pin Shines collection. Unlocks and selected shine are serialized in the existing synced profile record, compatible with older profile JSON. Same points balance pays for poop models and shines. A pin cluster uses the most recent pooper's equipped shine.

## Checks performed

- All app and test Swift files syntax-parsed (`swiftc -frontend -parse`).
- Linux Swift platform-independent core target compiled (`swift build`).
- Linux Swift test sources compiled; execution blocked at the environment link step (`libswiftObservation.so` missing `swift::threading::fatal`). **Do not claim XCTest tests executed.**
- 17 Python verifier tests passed; app plist and both YAML files parsed successfully.
- Archive integrity and content hashes separately checked against the unpacked finished tree, including hidden `.git` contents and both symlinks.

## Unverified on an actual iPhone

- Exact visual placement in small-screen/dynamic-type layouts and while the keyboard is open.
- Camera viewport preservation between fast tab switches, after CloudKit arrives, and at different MapKit tile states.
- Glow appearance on very bright satellite/standard map backgrounds, animation smoothness, and map-pin hit areas.
- Full purchase flow between *two* iCloud devices, especially simultaneous/offline purchases; profile-based purchases have not been made into an atomic server transaction.

## Manual QA before shipping

1. Scroll to the bottom on Groups, Calendar, Me, and all Home drawer states. The last control must remain above the bar and tappable.
2. Pan/zoom Home, switch to each tab and back, and confirm the map viewport is unchanged. Repeat after switching Standard/Satellite/Hybrid and a sync.
3. Tap an ordinary poop pin: white rays appear behind the model without a solid circle or geographic-position shift. Close it: rays vanish immediately. Repeat on a multi-person pin and with Reduce Motion enabled.
4. Purchase and equip one shine. Confirm points deduction once, persistence after relaunch, and appearance to a friend on selection. Verify existing cosmetic purchases still deduct from that same balance.
5. Load old backup/profile JSON (before shine fields) to verify it defaults to Classic White without deleting prior cosmetics/history.
