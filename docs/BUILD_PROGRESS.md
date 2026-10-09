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

## Session 4 (2026-10-09): Lee's decisions on the audit — part 1 (backend-independent)

No toolchain here either (download.swift.org is blocked from this container): nothing below was compiled or
run. Every change was traced by hand; **the first Codemagic `ios-check` run is the compile check.**

Decisions applied:
- **Counting rule.** Only live-logged poops count for leaderboards (group + friends), achievements, group
  trophies and the social (group / friends) highlights. Poops *added later*, *imported* (new
  `PoopEvent.imported` flag, set by Import) or *corrected afterwards* (`manuallyAdjusted`) stay in history,
  the calendar, personal stats and personal highlights. `PoopLike.countsForRanking` is the one rule;
  `GroupEvent` carries the two flags so every member applies it. "Corrected" now means the start time, the
  end time of an already finished poop, or the pin's coordinates changed; renaming a place, ending a
  still-running timer from the editor, or toggling group sharing are not corrections. Old records without
  the flags decode as before (tolerant decoders on `PoopEvent`, `GroupEvent`, `AppSettings`).
- **No solo party farm.** Party Animal and Perfect Attendance only count parties that at least one other
  person joined (`MyState.confirmedSocialParties`, device-local like `confirmedSocialSessions`).
- **International Incident** needs two *different members* in two different countries, from live logs.
- **Poop With Me has no 3-hour cutoff while someone is still in it**; only sessions where nobody is pooping
  any more age out. The "Still pooping?" reminder, the timer and the "pooping now" presence are unchanged
  (they already ran until stopped).
- **No logging cooldown**, no anti-auto-tapper change (0.06 s guard, uncapped) — nothing added.
- **Blocking stays friends-only**, and the gap is closed: a blocked person can no longer come back through
  the accept/complete handshake steps, a stale friend link synced from another device, their lingering
  shared zone, or a repeated `upsertFriendLink`. `block` drops the link + cached history on the spot and
  keeps the handle for the Blocked list (`AppSettings.blockedHandles`); a block made on another device drops
  the friend here when settings sync. Unblocking is the only way back.
- **Notification JOIN checks.** `Store.canJoinParty` / `canJoinPWM`: a JOIN (notification action, Home card,
  party page) is honoured only for a scheduled party inside its window that I haven't joined, or an open
  session I'm not already pooping in; otherwise the app explains (already in / cancelled / over / not yet)
  instead of silently creating a poop. A JOIN tapped before the party/session synced still counts +1 at
  once; if the target turns out over or cancelled the poop stays and the dead reference is detached.
- **Map pins** show each owner's equipped poop (newest pooper of the spot; same in the pin card and the
  shine shop previews); the equipped shine still appears only when the pin is tapped.
- **Settings stays behind the 3D poop on YOU** (no change).
- UI / accessibility / Dark Mode: points figures use grouping everywhere ("100,000 PTS"); history rows
  use the faceless 3D poop instead of the emoji; "imported" label in history; rarity pills use white ink
  on blue/violet; locked UNLOCK buttons use adaptive ink; period pickers read TODAY / WEEK / MONTH on both
  YOU and group pages; onboarding secondary buttons match the rest (NOT NOW / SKIP FOR NOW); VoiceOver
  labels for avatar part/tone pickers, group icon picker, trophies (locked + progress), invite card
  buttons, section buttons, onboarding step indicator; combined elements for stat tiles, leader rows,
  participant tiles, history rows; Reduce Motion honoured by the friend pulse, flying poops, confetti,
  the busy spinner, the blob background and the idle 3D sway.
- Tests: `ShittyFriendsTests/CountingRulesTests.swift` (counting rule, corrections, tolerant decoding,
  solo parties, JOIN checks, session cutoff, blocking paths, International Incident).

## Session 4 (2026-10-09): part 2 — Firebase backend replaces CloudKit

Still no Swift toolchain in the container; the Cloud Functions were type-checked with `tsc` (clean),
the Python preflight tests pass (19), YAML parses. **The Swift side is unverified until `ios-check`.**

What changed (decision: Firebase Auth + Firestore + Cloud Functions + FCM, so a Google Play version
can share accounts/friends/groups; handoff Hard Rule 2.1 dropped):
- **Backend** (`firebase/`): `firestore.rules` enforce the visibility model (friends read full history;
  group members read group copies; blocks veto requests/friendships; `memberIDs`/`bannedIDs` client
  read-only), `firestore.indexes.json`, Cloud Functions in TypeScript (`onPoopAnnounced` fan-out with
  per-friend/per-group levels, quiet hours, private lock screen; Poop With Me invite/join pushes; party
  invites; friend request/acceptance pushes; `requestJoinGroup` / `approveJoin` / `declineJoin` /
  `cancelJoinRequest` / `kickMember` (bans) / `unbanMember` / `leaveGroup` / `deleteGroup`;
  `deleteAccount`; daily `cleanupExpired`). `firebase/README.md` documents the schema.
- **iOS services** (`ShittyFriends/Services/Firebase/`): `FirebaseConfig` (+ `FirestorePaths`,
  `CloudAvailability`), `FirestoreCoder`, `AuthService` (Sign in with Apple; Google when the config
  carries a CLIENT_ID), `FirebaseSync` (queued writes + live listeners for my records, friends,
  groups, spaces, requests; one-shot fetches after a notification tap; `announce` for poop alerts),
  `SocialService` (friend requests/friendships, group callables, spaces, blocks mirror, account
  deletion), `PushService` (FCM token per device, NSE settings file).
  Removed: `Services/CloudKit/*`, `Services/Pings/PingService`, `Services/Crypto/AESSealer`,
  `Core/Social/PingPlanner` (kept for reference under `docs/legacy-cloudkit/sources/`, with the
  CloudKit schema and docs).
- **Core**: `FriendLink` (userID, status, notify, requestID), `OutgoingInvite` (token only),
  `IncomingFriendRequest`, `GroupLink.status` (requested/active), `GroupInfo.inviteCode`,
  `GroupMember` without inbox, new `GroupJoinRequest` + `RecordRef.joinRequest`, `SpaceLink.title`,
  `ZoneRef.group/space(_:ownerID:me:)`, tolerant decoders everywhere, `AppSettings.timeZoneID`.
  Store: handshake rewritten on request/friendship records (`beginFriendRequest`, `markRequestSent`,
  `acceptFriendRequest`, `friendshipConfirmed`, `friendshipEnded`); groups with owner approval
  (`registerGroupRequest`, `groupApproved`, `groupRequestEnded`, `joinRequests`, `settleJoinRequest`,
  `pendingGroupLinks`); `groupSummaries` lists members only. `Pings.swift` keeps `PingKind`,
  `NotificationCategory`, `PushField`, a settings-only `PingDirectory` and `NotificationTextBuilder`
  (same copy as the server). Deep links: friend invite v2 carries the inviter's id (v1 still parses),
  group invite carries the join code; iCloud share links are gone.
- **App**: `AppModel` wires auth → sync/social/push; effects map onto Firestore (`.ping(.poop)` →
  `announce` after the Undo window; invites/joins are server-pushed); sign-out keeps local data and
  pauses sync, a different account signing in resets the device; `deleteAllMyData` = server-side
  `deleteAccount` + local wipe. `AppDelegate` hands the APNs token to FCM. Notification taps resolve
  the group/space from the push (`sf_group_id` / `sf_space`) and read it before JOIN attaches.
  NSE re-renders alert text from push data with the device's private-mode / quiet-hours file.
- **UI**: onboarding gains a sign-in step (skippable: logging works without an account);
  `SignInView` also behind YOU → Settings → Account (sign in / sign out / delete account);
  GROUPS shows "WAITING FOR APPROVAL"; group page shows "WANT TO JOIN" with LET IN / decline for the
  owner; join sheet reads "ASK TO JOIN"; removal copy says they can't rejoin.
- **Build**: `project.yml` adds the firebase-ios-sdk (Auth, Firestore, Functions, Messaging) and
  GoogleSignIn packages; entitlements drop iCloud and add Sign in with Apple; `Info.plist` drops
  `CKSharingSupported` and carries a Google redirect placeholder; `codemagic.yaml` injects
  `GoogleService-Info.plist` from the `firebase` group, replaces the CloudKit workflows with
  `firebase-deploy`; `scripts/verify_signing_profiles.py` checks Sign in with Apple instead of CloudKit.
- **Tests**: `PingTests` → `HandshakeTests` (request/friendship flow, declines, unfriend, group
  requests/approvals); `SocialTests`, `HardeningTests`, `CountingRulesTests`, `CoreLogicTests`,
  `ExportAndMeshTests` updated for the new models.
- **Docs**: `docs/SETUP.md` rewritten (Apple portal incl. APNs key + Sign in with Apple, Firebase
  console steps, Codemagic `firebase` group, device test plan); handoff revised (§2.1, §29, §47 rules
  14/17 + new 21–24, §50); `firebase/README.md`.

Review pass before packaging (two read-through reviews, no compiler available here): a poop logged
while a join request is pending no longer mirrors into that group; the onboarding colour list and an
`async` call inside `??` were compile errors; the `/spaces` read rule is now provable for the
"spaces I'm in" listener; existing friendships and pending requests replayed on start no longer
toast; a freshly created group waits for its create batch before its listener attaches (the rules'
`get()` on a missing document used to read as "group gone"); an accepted request is checked against
the friendship document before being reported as declined.

Not done / needs the real device + project: APNs key and Firebase console setup are the owner's;
first compile; the Google sign-in URL scheme on local Xcode builds; the privacy label.
