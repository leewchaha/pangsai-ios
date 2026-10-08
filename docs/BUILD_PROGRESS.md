# Build progress (for resuming work)

Decisions (from Lee, 2026-10-06): anonymous public-DB pings for alerts; iOS 18 minimum; build via
XcodeGen + Codemagic; Lee pastes Codemagic logs back for fixes (no Mac pairing).

Architecture:
- Core/ (pure Swift, Linux-tested via Tools/LinuxCore): models, Store (local-first, emits Effects),
  logic (points, achievements, stats, highlights, handles), PingPlanner (ping routing, subscriptions,
  NSE directory, incoming-ping decisions), handshake, export/zip, PoopMesh.
- Services/: CloudSync (2x CKSyncEngine: private + shared), ShareService (Me zone private share with
  participants by user record ID; group zones public read-write link; session zones private RW;
  friend invite cards = record share with public read-only link → https link works in any messenger),
  PingService (public DB `Ping` records + query subscriptions), AESSealer (CryptoKit, shared w/ NSE),
  NotificationManager (local notifs), LocationService (one-shot).
- App/: AppModel (+Social, +Data) wires Effects → services; AppDelegate/SceneDelegate.
- DesignSystem/: Theme, Components (sticker style), Avatar (Canvas), 3D (SceneKit procedural poop,
  trophies, RenderCache snapshots, PoopStageView live).
- NotificationService/: NSE rewrites anonymous pings into "💩 @lee is pooping" using App Group directory.

Verify APIs with /usr/local/bin/sdkgrep <Framework> '<regex>' (iOS 26.5 SDK interfaces at /opt/sdkref).
Linux tests: source scratchpad env.sh; cd Tools/LinuxCore; swift build --build-tests -Xswiftc -swift-version -Xswiftc 5; swift test --skip-build

---

## Home drawer / points / location follow-up (2026-10-07)

- Poop location attachment defaults ON for new/unprompted users. iOS location permission is requested contextually on the first located poop; denial turns the default back off. No background tracking was added.
- Removed the daily points cap. The per-session cap and tap-rate protection remain.
- Repriced the cosmetic ladder for an uncapped-per-day economy: 120 PTS for the first paid cosmetic up to 12,000 PTS for Legendary. Existing unlock purchase costs remain historical.
- Home's poop activity surface is now a pull-up drawer. Collapsed state shows only the POOPING/current-session control; pulling up reveals invites, friend status, and today's compact status.

## Session 2 (2026-10-07): review + handoff gap closure

Verification done (no Xcode available): three independent read-only reviews against the iOS 26.5 SDK
interfaces (services, design system, feature views) + a stub-SDK type-check harness for the CloudKit /
AppModel layer, then a full handoff audit (all 20 §47 rules, every section). Linux core suite: 81 tests.

Fixed:
- Compile error: `.annotationTitles` applied to `Map` (it's a MapContent modifier) → removed.
- Sync: changes made before the sync engines start (offline launch) were silently dropped → persisted
  queue (`engine-queue.json`) replayed on start; fast start when the user ID is already known;
  last-write-wins queue; zone deletes drop pending saves and are never "recovered".
- Zone deletions honour `Deletion.reason` per the CKSyncEngine docs (deleted/purged/encryptedDataReset →
  wipe local copy, never re-send); own delete-all echo ignored for 24h.
- Delete-all keeps the iCloud user ID (app keeps working without relaunch) and deletes ping subscriptions.
- Always registers for remote notifications (sync pushes need no alert permission).
- Group integrity: CloudKit share permissions are all-or-nothing, so every device now checks the last
  writer of group/session records (`RemoteChange.upsertFrom`, `Store.isAllowedWriter`) and re-saves its
  own records if someone tampers with or deletes them (`repairMyGroupRecords` after each full fetch).
  Owner can remove members (share participant + records).
- Unfriend revocation self-heals (`reconcileHistoryShare`, at most every 10 min).
- Rule 11: joining a group no longer copies the last 31 days; groups only see poops logged after joining.
- Points: import never brings points; there is no daily earning cap. The per-session cap and anti-auto-click rate limit remain, while cosmetic prices are scaled for long-term progression.
- Bug: clearing the end time of a finished timer made it "live" again → blocked in Store + editor.
- Notification JOIN (PWM / party) counts +1 and starts the timer before any network
  (`attachToPWM` / `attachToParty` attach the already-counted poop later; never double-counts).
- Presentation races (sheet closing while a cover opens) → `presentSession(afterDismissal:)`.
- Session Undo pill (6 s); watch Poop With Me after your own DONE (done card + TODAY card + sheet);
  "@sam joined you." toast; 💩 reactions fly as the sender's 3D cosmetic.
- Duplicate-handle labels in PWM tiles, invites and party guest lists (`Store.labels(in:)`).
- Group trophies (Full House, Synchronized, Tag Team, Party On, Night Shift Crew, International Incident),
  friends' weekly ranking, place search + name filter in the poop editor.
- Private lock-screen mode now also covers local notifications and friend-request alerts; group
  "Highlights only" now delivers a weekly per-group highlights alert.
- Neutral date-of-birth age check (not stored) with a confirm step before blocking.
- Ping records readable by signed-in iCloud users only (`_icloud`, was `_world`).
- `VERSIONING_SYSTEM = apple-generic` so Codemagic's `agvtool` build-number step works.
- docs/SETUP.md written (portal, API key, Codemagic groups, CloudKit deploy, two-phone test plan).

Known limits / open product decisions (documented, not bugs):
- A removed group member can rejoin with the group link (CloudKit public share links can't be
  rotated without recreating the share). Owner can remove them again; deleting the group ends it.
- Group owner leaving deletes the group for everyone (no ownership transfer yet).
- Poop With Me / party-attendance achievement progress is stored per device (not synced).
- Perfect Attendance only sees friend-only parties for 24 h after they end (their zone is cleaned up).
- Ping metadata: `kind` and creator/time are visible to the developer in the public DB (payloads are
  sealed; no handles, locations or history). Orphaned pings of uninstalled senders stay until deleted
  manually (they expire logically via `exp`).
- Live Activity / Dynamic Island, widgets: handoff §45-46 "later", not built.

## Session 2 follow-up (2026-10-07): CI signing error diagnosis

- `ios-testflight` failed at `fetch-signing-files` with `--issuer-id: Missing value ISSUER_ID`.
- Root cause is an unavailable/empty `APP_STORE_CONNECT_ISSUER_ID` runtime environment variable;
  the YAML already references the correct `appstore_credentials` group, but the secret
  must be entered and enabled in Codemagic, not committed to the project.
- Added a secrets-safe preflight to `codemagic.yaml` before code generation and signing,
  plus a Codemagic UI troubleshooting guide in `docs/SETUP.md`.
- No app Swift code, signing identities, or profiles changed; actual TestFlight signing
  requires the account owner to configure their private credentials in Codemagic.

## Session 3 (2026-10-08): user audit fixes, Home activity avatar, points re-audit

No Swift toolchain was available (download.swift.org / registries blocked), so nothing here was compiled or
run. Three independent read-only reviews checked the diff for compile errors and traced every points/zip test
by hand. **First Codemagic build will be the compile check.**

- Points: removed the 30/60-tap tiers (taps 61+ silently paid 0 while the 50-pt cap was usually not
  reached → "tapping stops giving anything"). Now every earning tap = 1 pt (crit +1) until the 50-pt session
  cap; session screen shows a meter + "SESSION FULL". Deleting a poop banks its points in
  `UserProfile.bankedHalfPoints` (max-merged across devices); Undo still erases a mis-tap fully. New
  sessions never show the previous session's combo/cap (`resetTapFeedback`, `tapEventID`).
- Tab bar overlap: shell no longer relies on an outer `safeAreaInset`; every tab/pushed scroll view uses
  `.clearsTabBar()` (env `tabBarClearance`). Home pads its overlays/drawer and the Map's safe area itself.
- Home: my avatar above POOPING (live ring when friends are pooping, red badge for PWM invites, live parties,
  friend requests); tap opens the drawer. Drawer shows parties + requests again (they were only in the unused
  `TodayView`), tap/VoiceOver toggle, hidden panel no longer swallows map pans. "Show all pins" button,
  per-filter empty messages.
- Pin shines: Canvas + TimelineView, breathing glow + drifting motes, no rotation; static frame in the shop grid.
- Location (product = location pinning, default ON): honest onboarding copy, removable 📍 chip per poop,
  Open-iOS-Settings paths when denied. Onboarding: Back button, tips (Settings = tap your poop on YOU, Home avatar).
- Alerts: poop pings wait out the 6 s Undo window (flushed on background) and are throttled to 1 per 2 min.
- Groups: POOP WITH starts the timer on INVITE; joined groups default to "PWM / Parties only"; JOIN → PASTE INVITE.
- Misc: zip import (`ZipReader`), purchase confirmations, calendar legend + exact "+n", full party dates,
  friend notify menu, friendly iCloud errors, ½-point display, min label sizes, light scheme on session/highlights.

## Session 3b (2026-10-08): Lee's round-2 requests

Still no toolchain here: 4 independent read-only reviews (compile + hand-traced tests) instead. First Codemagic build = compile check.

- Points: no per-session cap (only the 60 ms auto-clicker guard). Prices ×~7–8: cosmetics 800 → 100,000,
  shines 5,000 → 70,000 (bought items keep their historical cost). Session shows "+N PTS THIS POOP" + balance.
- Session: swipe down anywhere (when scrolled to top) hides it; button renamed POOP NOW.
- Home map: every located poop in history; same spot (25 m) = one pin with a count; tap → list (4 rows
  visible, scroll for more) with who/when/duration. Clustering memoised (`MapPinCache`); open pin re-resolved
  each render. Tapping empty map closes the pin card and the drawer. YOU: tapping empty space folds sections.
- Location: no opt-out anywhere (Settings toggle, session chip removal and editor "Remove location" gone).
  Settings shows iOS permission status + fix. Group "Include locations" kept (sharing scope, not on/off).
- Calendar: single month grid with only the rows it needs, swipe/chevrons with slide animation, smaller
  cells, aqua location dot removed (pink = with friends, corner dot).
- Highlights: stories viewer (tap/hold/swipe, auto-advance 5.5 s, smooth cross-fade into the poster),
  personal only on YOU; groups get their own stories from the group page (▶ PLAY). Posters redrawn on a fixed
  360×640 canvas scaled for preview and exported at ×3 (same layout everywhere, every handle shrinks instead of
  clipping). Profile poster carries a friend-invite QR.
