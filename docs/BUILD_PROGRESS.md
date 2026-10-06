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
