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
- Points: import never brings points; daily cap keyed on `createdAt` (can't dodge by editing start).
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
