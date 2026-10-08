import MapKit
import SwiftUI

/// Map-first home. Locations are the latest poop location per person, never live tracking.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabBarClearance) private var tabBarClearance
    @AppStorage("sf.home.mapStyle") private var mapStyleRaw = HomeMapStyle.standard.rawValue
    @AppStorage("sf.map.showProfileBadges") private var showProfileBadges = true
    /// The shell owns camera state across tab reconstruction; never start .automatic on return.
    @Binding var position: MapCameraPosition
    @Binding var cameraInitialized: Bool
    @State private var filter: Filter = .everyone
    /// The open pin, remembered by the poops it contains (a cluster's id changes when a new poop
    /// lands there), and re-resolved against the live clusters on every render so the card is fresh.
    @State private var selectedPointIDs: Set<String>?
    /// Full-history clustering is memoised; it only reruns when the underlying data changes.
    @State private var pinCache = MapPinCache()
    @State private var showFriends = false
    @State private var showAddFriends = false
    @State private var instantFlash: String?
    @State private var activityExpanded = false
    @GestureState private var activityDragY: CGFloat = 0

    /// The POOPING control's height (collapsed drawer).
    private let collapsedHeight: CGFloat = 76
    /// The activity avatar row that sits just above the POOPING button.
    private let activityRowHeight: CGFloat = 58
    private let activityRowSpacing: CGFloat = 8
    /// Everything visible at the bottom while the drawer is closed.
    private var collapsedStackHeight: CGFloat { activityRowHeight + activityRowSpacing + collapsedHeight }

    enum Filter: Hashable {
        case everyone, me, friends, group(ZoneRef)
    }

    enum HomeMapStyle: String, CaseIterable {
        case standard, satellite, hybrid

        var shortTitle: String {
            switch self {
            case .standard: return "MAP"
            case .satellite: return "SAT"
            case .hybrid: return "HYB"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .standard: return "Standard map"
            case .satellite: return "Satellite map"
            case .hybrid: return "Hybrid map"
            }
        }
    }

    /// Things waiting for me personally: Poop With Me invites, live parties, friend requests.
    struct Activity {
        var watchable: [LiveSessionView]
        var invites: [LiveSessionView]
        var parties: [PartyView]
        var requests: [IncomingFriendRequest]
        var liveFriends: [FriendSummary]

        var waitingCount: Int { invites.count + parties.count + requests.count }
        var isEmpty: Bool { waitingCount == 0 && watchable.isEmpty && liveFriends.isEmpty }
    }

    private var store: Store { model.store }
    private var mapStyle: HomeMapStyle { HomeMapStyle(rawValue: mapStyleRaw) ?? .standard }

    /// Home shows every located poop in history. Poops at the same spot (within 25 m) share one pin
    /// with a count; tapping it lists them all.
    private func computePoints() -> [MapPoint] {
        let groups = Set(store.groupSummaries.map { $0.link.zone })
        switch filter {
        case .everyone: return store.mapPoints(includeMine: true, friendIDs: nil, groupZones: groups)
        case .me: return store.mapPoints(includeMine: true, friendIDs: [], groupZones: [])
        case .friends: return store.mapPoints(includeMine: false, friendIDs: nil, groupZones: [])
        case .group(let z): return store.mapPoints(includeMine: false, friendIDs: [], groupZones: [z])
        }
    }

    /// Cheap fingerprint of everything the pins depend on. Taps during a session don't change it
    /// (they don't touch `updatedAt` or locations), so the map isn't re-clustered per tap.
    private var pinKey: MapPinCache.Key {
        var mine = 0
        var mineStamp = Date.distantPast
        for e in store.my.events.values where e.location != nil {
            mine += 1
            if e.updatedAt > mineStamp { mineStamp = e.updatedAt }
        }
        var friendEvents = 0
        var friendStamp = Date.distantPast
        for f in store.cache.friends.values {
            friendEvents += f.events.count
            if let d = f.lastFetchedAt, d > friendStamp { friendStamp = d }
        }
        // Group events are often replaced in place (a live session ending, "Include locations"
        // toggled, an edit mirrored), so count located ones and track the newest update too.
        var groupEvents = 0
        var groupStamp = Date.distantPast
        for z in store.cache.zones.values {
            for e in z.events.values where e.location != nil {
                groupEvents += 1
                if e.updatedAt > groupStamp { groupStamp = e.updatedAt }
            }
        }
        return MapPinCache.Key(filter: String(describing: filter), mine: mine, mineStamp: mineStamp,
                               friendEvents: friendEvents, friendStamp: friendStamp,
                               groupEvents: groupEvents, groupStamp: groupStamp, groups: store.groupSummaries.count)
    }

    private func isSelected(_ cluster: MapCluster) -> Bool {
        guard let ids = selectedPointIDs else { return false }
        return cluster.points.contains { ids.contains($0.id) }
    }

    private func activity(friends: [FriendSummary]) -> Activity {
        Activity(
            watchable: store.liveEvent == nil ? store.watchableSessions() : [],
            invites: store.pendingInvites(),
            parties: store.parties().filter { $0.party.isJoinable(now: Date()) && store.myRSVP($0)?.joinedAt == nil },
            requests: store.friendRequests,
            liveFriends: friends.filter { $0.live != nil }
        )
    }

    var body: some View {
        let pins = pinCache.pins(for: pinKey) { computePoints() }
        let pts = pins.points
        let clusters = pins.clusters
        let selected = clusters.first { isSelected($0) }
        let friends = store.friendSummaries()
        let act = activity(friends: friends)

        NavigationStack {
            GeometryReader { proxy in
                let usable = max(0, proxy.size.height - tabBarClearance)
                let expandedHeight = min(max(340, usable * 0.56), 520)
                let drawerTravel = max(0, expandedHeight - collapsedHeight)
                let drawerBase = activityExpanded ? CGFloat.zero : drawerTravel
                let drawerOffset = min(max(drawerBase + activityDragY, 0), drawerTravel)

                ZStack {
                    mapLayer(clusters)

                    VStack(spacing: 8) {
                        topBar(requests: store.friendRequests.count)
                        filters
                        Spacer()
                    }
                    .padding(.top, 6)
                    .gutter()

                    // Cards floating over the map, always above the closed drawer.
                    VStack {
                        Spacer()
                        if let cluster = selected {
                            ClusterCard(cluster: cluster) {
                                withAnimation(Motion.snappy) { selectedPointIDs = nil }
                            }
                            .gutter()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if pts.isEmpty && !activityExpanded {
                            emptyMapCard
                                .gutter()
                        }
                    }
                    .padding(.bottom, tabBarClearance + collapsedStackHeight + 12)

                    VStack {
                        Spacer()
                        homeDrawer(friends: friends, activity: act, clusters: clusters)
                            .frame(height: activityRowHeight + activityRowSpacing + expandedHeight, alignment: .top)
                            .offset(y: drawerOffset)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                    // Clip first, then lift: the hidden part of the drawer must never show through
                    // (or under) the floating tab bar.
                    .clipped()
                    .padding(.bottom, tabBarClearance)
                }
                .overlay(alignment: .bottom) {
                    // UndoBar carries its own 100pt bottom padding; land it just above the activity row.
                    UndoBar().padding(.bottom, max(0, tabBarClearance + collapsedStackHeight + 14 - 100))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showFriends) { FriendsView() }
            .sheet(isPresented: $showAddFriends) { AddFriendsView().environment(model) }
            .onAppear {
                seedInitialCameraIfNeeded(clusters)
                model.startPresencePolling()
            }
            .onChange(of: clusters.map(\.id)) { _, _ in
                seedInitialCameraIfNeeded(clusters)
            }
            .onDisappear { model.stopPresencePolling() }
        }
    }

    // MARK: Map

    /// A concrete initial camera only once; later changes to pins do not recenter the map.
    private func seedInitialCameraIfNeeded(_ clusters: [MapCluster]) {
        guard !cameraInitialized, !clusters.isEmpty else { return }
        fit(clusters, animated: false)
        cameraInitialized = true
    }

    /// Frames every pin currently on the map (the recenter button and the first launch).
    private func fit(_ clusters: [MapCluster], animated: Bool) {
        let latitudes = clusters.map(\.latitude)
        let longitudes = clusters.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: min(max((maxLat - minLat) * 1.25, 0.025), 150),
                                    longitudeDelta: min(max((maxLon - minLon) * 1.25, 0.025), 350))
        let region = MapCameraPosition.region(MKCoordinateRegion(center: center, span: span))
        if animated {
            withAnimation(Motion.soft) { position = region }
        } else {
            position = region
        }
    }

    private var selectedMapStyle: MapStyle {
        switch mapStyle {
        case .standard: return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        }
    }

    private func mapLayer(_ clusters: [MapCluster]) -> some View {
        baseMap(clusters).mapStyle(selectedMapStyle)
    }

    private func baseMap(_ clusters: [MapCluster]) -> some View {
        // Keep the tap detector on the Map itself, not on a transparent overlay;
        // overlays would intercept MapKit pan and pinch gestures.
        MapReader { mapProxy in
            Map(position: $position) {
                ForEach(clusters) { cluster in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude), anchor: .center) {
                        PoopPin(
                            cluster: cluster,
                            selected: isSelected(cluster),
                            shine: store.person(for: cluster.ownerIDsByRecency.first ?? "")?.pinShine ?? .classicWhite,
                            profile: cluster.ownerIDsByRecency.first.flatMap { store.person(for: $0) },
                            showProfileBadge: showProfileBadges
                        )
                        .onTapGesture {
                            Haptics.tick()
                            withAnimation(Motion.bouncy) {
                                activityExpanded = false
                                selectedPointIDs = Set(cluster.points.map(\.id))
                            }
                        }
                    }
                }
            }
            .mapControls { }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                // Tapping empty map closes whatever is open (pin details, the activity drawer).
                // Annotation taps also pass through the Map's recognizer, so a touch on ANY pin
                // is left to the annotation handler, which selects the newly tapped pin.
                guard selectedPointIDs != nil || activityExpanded else { return }
                let tappedPin = clusters.contains { cluster in
                    let coordinate = CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)
                    guard let point = mapProxy.convert(coordinate, to: .local) else { return false }
                    return hypot(point.x - tap.location.x, point.y - tap.location.y) <= 36
                }
                if !tappedPin {
                    withAnimation(Motion.snappy) {
                        selectedPointIDs = nil
                        activityExpanded = false
                    }
                }
            })
            // Map(position:) writes gestures into the shell-owned camera binding;
            // a map tap should only dismiss details, never reset the camera.
            // The map draws edge to edge, but frames regions (and Apple's legal label) inside
            // the area not covered by the top bar, the activity row/POOPING and the tab bar.
            .safeAreaPadding(.top, 96)
            .safeAreaPadding(.bottom, tabBarClearance + collapsedStackHeight + 4)
            .ignoresSafeArea()
        }
    }

    private func topBar(requests: Int) -> some View {
        HStack(spacing: 8) {
            Text("HOME")
                .font(.heading(12))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(Palette.ink))
                .accessibilityAddTraits(.isHeader)

            mapStyleToggle

            Spacer(minLength: 2)

            Button { showFriends = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Palette.paper)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.ink))
                    if requests > 0 {
                        CountBadge(count: requests)
                            .offset(x: 5, y: -5)
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(requests > 0 ? "Friends, \(requests) requests" : "Friends")
        }
    }

    private var mapStyleToggle: some View {
        HStack(spacing: 2) {
            ForEach(HomeMapStyle.allCases, id: \.self) { style in
                let selected = style == mapStyle
                Button {
                    Haptics.tick()
                    withAnimation(Motion.snappy) { mapStyleRaw = style.rawValue }
                } label: {
                    Text(style.shortTitle)
                        .font(.heading(10))
                        .foregroundStyle(selected ? Palette.paper : Palette.ink)
                        .frame(minWidth: 40, minHeight: 32)
                        .background {
                            if selected { Capsule().fill(Palette.ink) }
                        }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(style.accessibilityTitle)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.card.opacity(0.96)))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                chip("EVERYONE", .everyone)
                chip("ME", .me)
                chip("FRIENDS", .friends)
                ForEach(store.groupSummaries) { group in
                    chip(group.name.uppercased(), .group(group.link.zone))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ text: String, _ value: Filter) -> some View {
        Button {
            withAnimation(Motion.snappy) {
                filter = value
                selectedPointIDs = nil
            }
        } label: {
            Chip(text: text, fill: Palette.card.opacity(0.96), selected: filter == value)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    /// Explains an empty map for the filter that is actually selected.
    private var emptyMapCard: some View {
        let message: String
        switch filter {
        case .everyone:
            message = "Every poop with a location lands here — yours and your friends'."
        case .me:
            message = "Log a poop with location on and your pin lands here."
        case .friends:
            message = store.activeFriendLinks.isEmpty
                ? "Add friends to see where they last pooped."
                : "None of your friends have a located poop yet."
        case .group(let zone):
            let name = store.groupSummaries.first { $0.link.zone == zone }?.name ?? "this group"
            message = "Nobody in \(name) shares locations yet. Members can turn on “Include locations” in the group's settings."
        }
        return EmptyState(emoji: "🗺️", title: "NO POOP LOCATIONS YET", message: message)
            .calmSurface(Palette.card.opacity(0.97), radius: 20)
    }

    // MARK: Home activity drawer

    private func setDrawer(_ expanded: Bool) {
        Haptics.tick()
        withAnimation(Motion.snappy) {
            activityExpanded = expanded
            if expanded { selectedPointIDs = nil }
        }
    }

    private func homeDrawer(friends: [FriendSummary], activity act: Activity, clusters: [MapCluster]) -> some View {
        VStack(spacing: activityRowSpacing) {
            activityRow(act, clusters: clusters)
                .frame(height: activityRowHeight)

            VStack(spacing: 10) {
                ZStack(alignment: .top) {
                    poopingControl
                    // A drag strip lives inside the black control, so the collapsed state still shows only
                    // the POOPING button while avoiding a drag gesture that can accidentally trigger it.
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 36, height: 4)
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { setDrawer(!activityExpanded) }
                    .gesture(activityDrawerDrag)
                    .accessibilityElement()
                    .accessibilityLabel(activityExpanded ? "Hide activity" : "Show activity")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { setDrawer(!activityExpanded) }
                }
                .frame(height: collapsedHeight)

                ScrollView {
                    VStack(spacing: 12) {
                        if let message = model.availability.message {
                            InfoBanner(text: message, fill: Palette.paper2)
                        }

                        activityCards(act)
                        friendsStatusList(friends)
                        compactTodayStatus

                        if friends.isEmpty {
                            Button { showAddFriends = true } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "person.badge.plus")
                                    Text("ADD FRIENDS")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .font(.heading(11))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.paper2))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(12)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Palette.card.opacity(0.98))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 5)
                )
                // After the background: the hidden (clipped) panel must not swallow map pans.
                .allowsHitTesting(activityExpanded)
                .accessibilityHidden(!activityExpanded)
            }
        }
    }

    /// My avatar, just above POOPING: lights up when friends are pooping live and badges anything
    /// waiting for me (Poop With Me invites, live parties, friend requests). Tapping opens the drawer.
    private func activityRow(_ act: Activity, clusters: [MapCluster]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { setDrawer(!activityExpanded) } label: {
                HStack(spacing: 8) {
                    ActivityAvatar(person: store.meRef, live: !act.liveFriends.isEmpty, badge: act.waitingCount)
                    if let summary = activitySummary(act) {
                        HStack(spacing: 6) {
                            if !act.liveFriends.isEmpty {
                                HStack(spacing: -8) {
                                    ForEach(act.liveFriends.prefix(3)) { f in
                                        AvatarView(person: f.person, size: 22)
                                    }
                                }
                            }
                            Text(summary)
                                .font(.heading(10))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: activityExpanded ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Capsule().fill(Palette.card.opacity(0.97)))
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(activityAccessibilityLabel(act))
            .accessibilityHint(activityExpanded ? "Hides activity" : "Shows friends and invites")

            Spacer(minLength: 0)

            Button { fit(clusters, animated: true) } label: {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Palette.card.opacity(0.97)))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .disabled(clusters.isEmpty)
            .opacity(clusters.isEmpty ? 0.45 : 1)
            .accessibilityLabel("Show all pins")
        }
        .padding(.horizontal, 4)
        .animation(Motion.snappy, value: act.liveFriends.map(\.id))
        .animation(Motion.snappy, value: act.waitingCount)
    }

    private func activitySummary(_ act: Activity) -> String? {
        var parts: [String] = []
        if act.liveFriends.count == 1, let f = act.liveFriends.first {
            parts.append("@\(f.person.handle.uppercased()) IS POOPING")
        } else if act.liveFriends.count > 1 {
            parts.append("\(act.liveFriends.count) POOPING NOW")
        }
        if !act.invites.isEmpty { parts.append(act.invites.count == 1 ? "1 INVITE" : "\(act.invites.count) INVITES") }
        if !act.parties.isEmpty { parts.append(act.parties.count == 1 ? "PARTY LIVE" : "\(act.parties.count) PARTIES LIVE") }
        if !act.requests.isEmpty { parts.append(act.requests.count == 1 ? "1 REQUEST" : "\(act.requests.count) REQUESTS") }
        if parts.isEmpty && !act.watchable.isEmpty { parts.append("STILL GOING") }
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: " · ")
    }

    private func activityAccessibilityLabel(_ act: Activity) -> String {
        var parts = ["Activity"]
        if !act.liveFriends.isEmpty { parts.append("\(act.liveFriends.count) friends pooping now") }
        if act.waitingCount > 0 { parts.append("\(act.waitingCount) waiting for you") }
        return parts.joined(separator: ", ")
    }

    private var activityDrawerDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($activityDragY) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let end = value.predictedEndTranslation.height
                withAnimation(Motion.snappy) {
                    if end < -45 || value.translation.height < -45 {
                        activityExpanded = true
                        selectedPointIDs = nil
                    } else if end > 45 || value.translation.height > 45 {
                        activityExpanded = false
                    }
                }
            }
    }

    private func friendsStatusList(_ friends: [FriendSummary]) -> some View {
        let ordered = friends.sorted { lhs, rhs in
            if (lhs.live != nil) != (rhs.live != nil) { return lhs.live != nil }
            return (lhs.lastEvent?.startedAt ?? .distantPast) > (rhs.lastEvent?.startedAt ?? .distantPast)
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FRIENDS")
                    .font(.heading(10))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !friends.isEmpty {
                    Button("ALL →") { showFriends = true }
                        .font(.heading(10))
                        .foregroundStyle(Palette.ink)
                }
            }

            if ordered.isEmpty {
                Text("Add friends to see their latest poop status here.")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(ordered) { friend in
                    NavigationLink {
                        FriendDetailView(userID: friend.person.id)
                    } label: {
                        HStack(spacing: 10) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(person: friend.person, size: 38)
                                Circle()
                                    .fill(friend.live != nil ? Palette.lime : Palette.muted.opacity(0.45))
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HandleText(handle: friend.person.handle, size: 12)
                                if let live = friend.live {
                                    HStack(spacing: 5) {
                                        Text("POOPING NOW")
                                            .font(.heading(9))
                                            .foregroundStyle(Palette.ink)
                                        TimerText(start: live.startedAt, size: 10, color: Palette.muted)
                                    }
                                } else if let last = friend.lastEvent {
                                    Text("LAST POOP " + last.startedAt.formatted(.relative(presentation: .named)).uppercased())
                                        .font(.heading(9))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                } else {
                                    Text(friend.hasHistory ? "NO POOPS YET" : "WAITING FOR SHARED HISTORY")
                                        .font(.heading(9))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if friend.todayCount > 0 {
                                Text("\(friend.todayCount) TODAY")
                                    .font(.heading(9))
                                    .foregroundStyle(Palette.ink)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Palette.paper2))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    /// Everything addressed to me, newest-intent first. Same cards as the old TODAY screen.
    @ViewBuilder
    private func activityCards(_ act: Activity) -> some View {
        if !act.invites.isEmpty || !act.watchable.isEmpty || !act.parties.isEmpty || !act.requests.isEmpty {
            VStack(spacing: 7) {
                ForEach(act.invites) { view in
                    let host = view.participants.first(where: { $0.id == view.session.creatorID })?.person ?? store.person(for: view.session.creatorID)
                    let hostLabel = store.labels(in: view.zone)[view.session.creatorID] ?? "@" + (host?.handle ?? "someone")
                    InviteCard(
                        emoji: "💩",
                        title: "\(hostLabel.uppercased()) WANTS TO POOP WITH YOU",
                        subtitle: view.groupName ?? "Poop With Me",
                        fill: Palette.pink,
                        action: "JOIN",
                        primary: { model.joinPWM(view.session.id) },
                        secondary: { store.declinePWM(zone: view.zone, sessionID: view.session.id) }
                    )
                }
                ForEach(act.parties) { p in
                    InviteCard(
                        emoji: "🚨",
                        title: "POOP PARTY: \(p.party.title.uppercased())",
                        subtitle: p.groupName ?? "Happening now",
                        fill: Palette.tangerine,
                        action: "JOIN",
                        primary: { model.joinParty(p) },
                        secondary: nil
                    )
                }
                ForEach(act.watchable) { view in
                    let still = view.participants.filter { $0.status == .joined }.count
                    InviteCard(
                        emoji: "👀",
                        title: "POOP WITH ME · STILL GOING",
                        subtitle: "\(still) still pooping\(view.groupName.map { " · " + $0 } ?? "")",
                        fill: Palette.sun,
                        action: "WATCH",
                        primary: { model.sheet = .pwmWatch(view.session.id) },
                        secondary: nil
                    )
                }
                if let req = act.requests.first {
                    InviteCard(
                        emoji: "🤝",
                        title: "@\(req.person.handle.uppercased()) WANTS TO BE SHITTY FRIENDS",
                        subtitle: act.requests.count > 1 ? "+\(act.requests.count - 1) more" : "Tap to review",
                        fill: Palette.aqua,
                        action: "REVIEW",
                        primary: { showFriends = true },
                        secondary: nil
                    )
                }
            }
        }
    }

    private var compactTodayStatus: some View {
        let today = store.todayCount()
        let streak = store.stats().currentStreak
        return HStack(spacing: 8) {
            Text("\(today)")
                .font(.digits(29))
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText(value: Double(today)))
            Text(today == 1 ? "POOP TODAY" : "POOPS TODAY")
                .font(.heading(10))
                .foregroundStyle(Palette.ink)
            Spacer()
            if streak >= 2 {
                Text("🔥 \(streak) DAYS")
                    .font(.heading(10))
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var poopingControl: some View {
        if let live = store.liveEvent {
            Button { model.showSession = true } label: {
                HStack(spacing: 10) {
                    Circle().fill(Palette.sun).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CURRENTLY POOPING").font(.heading(11))
                        Text("Tap to open session").font(.ui(11, .medium)).opacity(0.64)
                    }
                    Spacer()
                    TimerText(start: live.startedAt, size: 20, color: .white)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(height: collapsedHeight)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
            }
            .buttonStyle(PressableStyle())
        } else {
            ZStack(alignment: .top) {
                PoopingButton { timed in
                    if timed {
                        store.startTimed()
                        model.showSession = true
                    } else {
                        let event = store.logInstant()
                        withAnimation(Motion.bouncy) {
                            instantFlash = Copy.instantLogged(seed: Copy.seed(event.id)).uppercased()
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation(Motion.soft) { instantFlash = nil }
                        }
                    }
                }
                if let flash = instantFlash {
                    Text(flash)
                        .font(.heading(10))
                        .foregroundStyle(Palette.inkFixed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.lime))
                        .overlay(Capsule().strokeBorder(Palette.inkFixed, lineWidth: 1))
                        // Above the activity row, over the map.
                        .offset(y: -(28 + activityRowHeight + activityRowSpacing))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

/// My avatar with a soft live ring (friends pooping now) and a count badge (things waiting for me).
struct ActivityAvatar: View {
    var person: PersonRef
    var live: Bool
    var badge: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(Palette.card)
                    .frame(width: 54, height: 54)
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 3)
                if live {
                    Circle()
                        .stroke(Palette.sun, lineWidth: 3.5)
                        .frame(width: 56, height: 56)
                        .scaleEffect(breathe && !reduceMotion ? 1.12 : 1)
                        .opacity(breathe && !reduceMotion ? 0.35 : 1)
                }
                AvatarView(person: person, size: 46)
                if live {
                    Text("💩")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Palette.inkFixed))
                        .offset(x: 18, y: 18)
                }
            }
            if badge > 0 {
                CountBadge(count: badge)
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: 58, height: 58)
        .onAppear { breathe = live }
        .onChange(of: live) { _, isLive in breathe = isLive }
        .animation(live ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: breathe)
    }
}

/// Small red count badge used on Home (activity, friend requests).
struct CountBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.heading(10))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Palette.tomato))
            .overlay(Capsule().strokeBorder(Palette.card, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Kept as a compatibility wrapper for old navigation references while Home replaces the Map tab.
struct PoopMapView: View {
    @State private var position: MapCameraPosition = .automatic
    @State private var initialized = false
    var body: some View { HomeView(position: $position, cameraInitialized: $initialized) }
}

/// A genuinely 3D-rendered, faceless poop model centered on the recorded coordinate.
/// Count and freshness labels are overlays: they never move MapKit's anchor point.
struct PoopPin: View {
    var cluster: MapCluster
    var selected: Bool
    var shine: PinShineID = .classicWhite
    var profile: PersonRef? = nil
    var showProfileBadge: Bool = true

    private var latestDate: Date? { cluster.latest?.date }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let justNow = latestDate.map {
                context.date.timeIntervalSince($0) >= 0 && context.date.timeIntervalSince($0) < 600
            } ?? false

            Object3DImage(subject: .poop(.classic), size: 54)
                .frame(width: 58, height: 58)
                .background {
                    // Only the tapped marker receives animated radiance. The fixed 58pt
                    // frame remains MapKit's geographic anchor (shine never shifts it).
                    if selected {
                        PinShineEffect(id: shine)
                            .frame(width: 92, height: 92)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // How many poops happened at this spot.
                    if cluster.count > 1 {
                        Text(cluster.count > 999 ? "999+" : "\(cluster.count)")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 18)
                            .background(Capsule().fill(Color.black))
                            .offset(x: 7, y: -4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showProfileBadge, let profile {
                        AvatarView(person: profile, size: 23, ring: false)
                            .frame(width: 23, height: 23)
                            .background(Circle().fill(.white))
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                            // Sits on the model's bottom-right edge, inside its map frame.
                            .offset(x: 0, y: -5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if justNow {
                        Text("just now")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white).shadow(color: Color.black.opacity(0.12), radius: 2, y: 1))
                            .offset(y: 13)
                            .fixedSize()
                    }
                }
                .contentShape(Circle())
                .animation(Motion.snappy, value: selected)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cluster.count) \(cluster.count == 1 ? "poop" : "poops") at \(cluster.latest?.label ?? "this spot")\(latestDate.map { Date().timeIntervalSince($0) < 600 ? ", latest just now" : "" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Soft, living radiance behind a selected map pin (or a shop preview). Nothing rotates: a breathing
/// glow, slow drifting light motes, and per-shine character (ripples, aurora, hue drift, flicker).
/// Drawn in one Canvas; created ONLY for a selected pin, so MapKit annotations never pay for it.
struct PinShineEffect: View {
    var id: PinShineID
    /// false = one still frame (shop grid thumbnails; six live effects at once would cost battery).
    var animated: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion || !animated
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { context in
            let t = still ? 2.0 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                PinShinePainter.paint(id, time: t, in: &ctx, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum PinShinePainter {
    struct Look {
        var glow: [Color]
        var motes: [Color]
        var moteCount: Int
        /// Mote life cycles per second.
        var moteSpeed: Double
        /// Breathing speed (radians per second).
        var breathe: Double
        var ripples = false
        var aurora = false
        var hueDrift = false
        var flicker = false
    }

    static let gold = Color(red: 1, green: 0.8, blue: 0.24)

    static func look(_ id: PinShineID) -> Look {
        switch id {
        case .classicWhite:
            return Look(glow: [.white], motes: [.white], moteCount: 6, moteSpeed: 0.22, breathe: 1.5)
        case .golden:
            return Look(glow: [gold], motes: [gold, .white], moteCount: 9, moteSpeed: 0.28, breathe: 1.3)
        case .electric:
            return Look(glow: [.cyan], motes: [.cyan, .white], moteCount: 10, moteSpeed: 0.5, breathe: 2.2, flicker: true)
        case .neonOrbit:
            return Look(glow: [.pink, .purple], motes: [.pink, .purple], moteCount: 6, moteSpeed: 0.25, breathe: 1.4, ripples: true)
        case .aurora:
            return Look(glow: [.mint, .cyan, .green], motes: [.mint, .white], moteCount: 5, moteSpeed: 0.18, breathe: 1.0, aurora: true)
        case .prismatic:
            return Look(glow: [.white], motes: [.red, .orange, .yellow, .green, .cyan, .purple], moteCount: 12, moteSpeed: 0.3, breathe: 1.6, hueDrift: true)
        }
    }

    private static func frac(_ x: Double) -> Double { x - floor(x) }
    /// Stable pseudo-random 0..<1 per index (no state, no allocation).
    private static func hash(_ i: Int, _ salt: Double) -> Double { frac(sin(Double(i) * 12.9898 + salt) * 43758.5453) }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    static func paint(_ id: PinShineID, time t: Double, in ctx: inout GraphicsContext, size: CGSize) {
        let style = Self.look(id)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let breath = 0.5 + 0.5 * sin(t * style.breathe)
        let flicker = style.flicker ? 0.78 + 0.22 * sin(t * 11.0) * sin(t * 6.7) : 1.0

        var base = style.glow[0]
        if style.hueDrift {
            base = Color(hue: frac(t * 0.07), saturation: 0.65, brightness: 1)
        }

        // 1. Breathing halo.
        let glowR = radius * CGFloat(0.8 + 0.14 * breath)
        ctx.opacity = (0.5 + 0.35 * breath) * flicker
        ctx.fill(
            Path(ellipseIn: circle(c, glowR)),
            with: .radialGradient(Gradient(colors: [base.opacity(0.9), base.opacity(0.32), base.opacity(0)]),
                                  center: c, startRadius: radius * 0.16, endRadius: glowR)
        )

        // 2. Aurora: soft colour clouds drifting side to side.
        if style.aurora {
            for i in 0..<3 {
                let color = style.glow[i % style.glow.count]
                let p = CGPoint(
                    x: c.x + radius * 0.34 * CGFloat(sin(t * 0.55 + Double(i) * 2.1)),
                    y: c.y - radius * 0.1 + radius * 0.14 * CGFloat(cos(t * 0.42 + Double(i) * 1.3))
                )
                let r = radius * CGFloat(0.5 + 0.08 * sin(t * 0.7 + Double(i)))
                ctx.opacity = 0.42
                ctx.fill(Path(ellipseIn: circle(p, r)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.85), color.opacity(0)]), center: p, startRadius: 0, endRadius: r))
            }
        }

        // 3. Neon ripples: flattened rings that swell outward and fade (no spinning).
        if style.ripples {
            ctx.opacity = 1
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 1.6))
                for i in 0..<3 {
                    let p = frac(t * 0.42 + Double(i) / 3)
                    let r = radius * CGFloat(0.36 + 0.58 * p)
                    let color = style.glow[i % style.glow.count]
                    layer.opacity = (1 - p) * 0.85
                    let ring = CGRect(x: c.x - r, y: c.y - r * 0.56, width: r * 2, height: r * 1.12)
                    layer.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: CGFloat(1 + 2.4 * (1 - p)))
                }
            }
        }

        // 4. Light motes: rise gently from around the pin, fade in and out.
        for i in 0..<style.moteCount {
            let angle = hash(i, 1) * .pi * 2
            let phase = frac(t * style.moteSpeed * (0.75 + 0.5 * hash(i, 2)) + hash(i, 3))
            let dist = radius * CGFloat(0.3 + 0.48 * phase)
            let p = CGPoint(
                x: c.x + CGFloat(cos(angle)) * dist,
                y: c.y + CGFloat(sin(angle)) * dist * 0.62 - radius * CGFloat(0.42 * phase)
            )
            let r = radius * CGFloat(0.075 * (1 - 0.45 * phase))
            var color = style.motes[i % style.motes.count]
            if style.hueDrift { color = Color(hue: frac(t * 0.07 + Double(i) / Double(style.moteCount)), saturation: 0.7, brightness: 1) }
            ctx.opacity = sin(phase * .pi) * flicker
            ctx.fill(Path(ellipseIn: circle(p, r)),
                     with: .radialGradient(Gradient(colors: [.white, color.opacity(0.85), color.opacity(0)]), center: p, startRadius: 0, endRadius: r))
        }
        ctx.opacity = 1
    }
}

/// Everything that happened at one pin: newest first, four rows visible, the rest scroll inside.
struct ClusterCard: View {
    @Environment(AppModel.self) private var model
    var cluster: MapCluster
    var close: () -> Void

    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 4

    var body: some View {
        let points = cluster.pointsByRecency
        let people = cluster.ownerIDsByRecency.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Object3DImage(subject: .poop(.classic), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cluster.latest?.label ?? "Poop spot")
                        .font(.heading(14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(points.count) \(points.count == 1 ? "POOP" : "POOPS") HERE\(people > 1 ? " · \(people) PEOPLE" : "")")
                        .font(.heading(9))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Palette.paper2))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close")
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(points) { point in
                        row(point)
                    }
                }
            }
            .scrollIndicators(points.count > ClusterCard.visibleRows ? .visible : .hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight(points.count))
        }
        .foregroundStyle(Palette.ink)
        .padding(13)
        .calmSurface(Palette.card.opacity(0.98), radius: 18)
    }

    private func listHeight(_ count: Int) -> CGFloat {
        let rows = CGFloat(min(max(count, 1), ClusterCard.visibleRows))
        // A sliver of the 5th row shows when there is more to scroll.
        let peek: CGFloat = count > ClusterCard.visibleRows ? 18 : 0
        return rows * ClusterCard.rowHeight + (rows - 1) * 6 + peek
    }

    private func row(_ point: MapPoint) -> some View {
        let person = model.store.person(for: point.ownerID)
        let isMe = point.ownerID == model.store.userID
        return HStack(spacing: 9) {
            if let person {
                AvatarView(person: person, size: 30)
            } else {
                Circle().fill(Palette.paper2).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                HandleText(handle: isMe ? "you" : (person?.handle ?? "someone"), size: 12)
                Text(point.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.ui(11, .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if point.isLive {
                    Text("POOPING NOW").font(.heading(9)).foregroundStyle(Palette.tomato)
                } else if let d = point.duration {
                    Text(StatsCalculator.formatDuration(d)).font(.digits(13))
                } else {
                    Text("LOGGED").font(.heading(9)).foregroundStyle(Palette.muted)
                }
                Text(point.date.formatted(.relative(presentation: .named)))
                    .font(.ui(10, .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: ClusterCard.rowHeight)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.paper2))
        .accessibilityElement(children: .combine)
    }
}

/// Memo for Home pins. A plain reference box held in @State (not observed): clustering a long
/// history with distance checks is the expensive part of Home, so it runs only when the key changes.
final class MapPinCache {
    struct Key: Hashable {
        var filter: String
        var mine: Int
        var mineStamp: Date
        var friendEvents: Int
        var friendStamp: Date
        var groupEvents: Int
        var groupStamp: Date
        var groups: Int
    }

    private var key: Key?
    private var points: [MapPoint] = []
    private var clusters: [MapCluster] = []

    func pins(for key: Key, compute: () -> [MapPoint]) -> (points: [MapPoint], clusters: [MapCluster]) {
        if key != self.key {
            points = compute()
            clusters = MapClustering.atRecordedLocations(points)
            self.key = key
        }
        return (points, clusters)
    }
}
