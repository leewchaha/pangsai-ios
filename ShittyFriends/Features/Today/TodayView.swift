import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showFriends = false
    @State private var showAddFriends = false
    @State private var launch = 0
    @State private var instantFlash: String?
    @State private var showWeek = false

    private var store: Store { model.store }

    var body: some View {
        let friends = store.friendSummaries()
        let today = store.todayCount()
        NavigationStack {
            ZStack {
                BlobBackground(colors: [store.profile.color.color] + friends.prefix(2).map { $0.person.color.color }, intensity: 0.055)
                ScrollView {
                    VStack(spacing: 18) {
                        header(requests: store.friendRequests.count)
                        if let msg = model.availability.message {
                            InfoBanner(text: msg, fill: Palette.paper2)
                        }
                        invitesSection
                        FriendCloud(friends: friends, showAdd: { showAddFriends = true })
                        myCount(today)
                        poopingArea
                        highlightsStrip
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                    .gutter()
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }

                FlyingPoops(trigger: launch, cosmetic: store.profile.equippedCosmetic)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { UndoBar() }
            .navigationDestination(isPresented: $showFriends) { FriendsView() }
            .sheet(isPresented: $showAddFriends) { AddFriendsView().environment(model) }
            .sheet(isPresented: $showWeek) { HighlightsView(period: .week, reference: Date()).environment(model) }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { model.startPresencePolling() }
            .onDisappear { model.stopPresencePolling() }
        }
    }

    // MARK: Header

    private func header(requests: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Date().formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.display(31))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Date().formatted(.dateTime.day().month(.wide)).uppercased())
                    .font(.heading(11))
                    .tracking(1.8)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { showFriends = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Palette.paper)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.ink))
                    if requests > 0 {
                        Text("\(requests)")
                            .font(.heading(10))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Circle().fill(Palette.tomato))
                            .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                            .offset(x: 5, y: -5)
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Friends")
        }
    }

    // MARK: Invites & parties

    @ViewBuilder private var invitesSection: some View {
        let invites = store.pendingInvites()
        let watchable = store.liveEvent == nil ? store.watchableSessions() : []
        let joinable = store.parties().filter { $0.party.isJoinable(now: Date()) && store.myRSVP($0)?.joinedAt == nil }
        if !invites.isEmpty || !watchable.isEmpty || !joinable.isEmpty || !store.friendRequests.isEmpty {
            VStack(spacing: 8) {
                ForEach(watchable) { v in
                    let still = v.participants.filter { $0.status == .joined }.count
                    InviteCard(emoji: "👀", title: "POOP WITH ME · STILL GOING", subtitle: "\(still) still pooping\(v.groupName.map { " · " + $0 } ?? "")", fill: Palette.sun, action: "WATCH", primary: {
                        model.sheet = .pwmWatch(v.session.id)
                    }, secondary: nil)
                }
                ForEach(invites) { v in
                    let host = v.participants.first(where: { $0.id == v.session.creatorID })?.person ?? store.person(for: v.session.creatorID)
                    let hostLabel = store.labels(in: v.zone)[v.session.creatorID] ?? "@" + (host?.handle ?? "someone")
                    InviteCard(emoji: "💩", title: "\(hostLabel.uppercased()) WANTS TO POOP WITH YOU", subtitle: v.groupName ?? "Poop With Me", fill: Palette.pink, action: "JOIN", primary: {
                        model.joinPWM(v.session.id)
                    }, secondary: {
                        store.declinePWM(zone: v.zone, sessionID: v.session.id)
                    })
                }
                ForEach(joinable) { p in
                    InviteCard(emoji: "🚨", title: "POOP PARTY: \(p.party.title.uppercased())", subtitle: p.groupName ?? "Happening now", fill: Palette.tangerine, action: "JOIN", primary: {
                        model.joinParty(p)
                    }, secondary: nil)
                }
                if let req = store.friendRequests.first {
                    InviteCard(emoji: "🤝", title: "@\(req.person.handle) WANTS TO BE SHITTY FRIENDS", subtitle: store.friendRequests.count > 1 ? "+\(store.friendRequests.count - 1) more" : "Tap to review", fill: Palette.aqua, action: "REVIEW", primary: {
                        showFriends = true
                    }, secondary: nil)
                }
            }
        }
    }

    // MARK: Count

    private func myCount(_ today: Int) -> some View {
        let streak = store.stats().currentStreak
        return HStack(alignment: .center, spacing: 10) {
            Text("\(today)")
                .font(.digits(36))
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText(value: Double(today)))
            VStack(alignment: .leading, spacing: 1) {
                Text(today == 1 ? "POOP TODAY" : "POOPS TODAY")
                    .font(.heading(12))
                    .foregroundStyle(Palette.ink)
                Text(Copy.todayLine(count: today, seed: today + Calendar.current.component(.day, from: Date())))
                    .font(.ui(12, .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer()
            if streak >= 2 {
                Text("🔥 \(streak)")
                    .font(.heading(14))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.paper2))
            }
        }
    }

    // MARK: POOPING

    @ViewBuilder private var poopingArea: some View {
        if let live = store.liveEvent {
            Button { model.showSession = true } label: {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.sun).frame(width: 10, height: 10)
                        Text("CURRENTLY POOPING").font(.heading(13)).foregroundStyle(Palette.paper)
                    }
                    TimerText(start: live.startedAt, size: 46, color: Palette.paper)
                    Text("TAP TO OPEN").font(.heading(9)).tracking(1).foregroundStyle(Palette.paper.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.ink))
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(spacing: 10) {
                ZStack {
                    PoopStageView(cosmetic: store.profile.equippedCosmetic, pulse: launch, hdr: true)
                        .frame(height: 158)
                    if let flash = instantFlash {
                        Text(flash)
                            .font(.heading(13))
                            .foregroundStyle(Palette.inkFixed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Palette.lime))
                            .overlay(Capsule().strokeBorder(Palette.inkFixed, lineWidth: 1.5))
                            .transition(.scale.combined(with: .opacity))
                            .offset(y: -56)
                    }
                }
                PoopingButton { timed in
                    launch += 1
                    if timed {
                        store.startTimed()
                        model.showSession = true
                    } else {
                        let e = store.logInstant()
                        withAnimation(Motion.bouncy) { instantFlash = Copy.instantLogged(seed: Copy.seed(e.id)).uppercased() }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_600_000_000)
                            withAnimation(Motion.soft) { instantFlash = nil }
                        }
                    }
                }
                Text("TAP FOR TIMER  ·  DOUBLE TAP TO LOG NOW")
                    .font(.heading(9))
                    .tracking(0.8)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Highlights

    @ViewBuilder private var highlightsStrip: some View {
        let cards = store.highlightCards(period: .day)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("TODAY IN SHIT", trailing: "WEEK →") { showWeek = true }
            if cards.isEmpty {
                Text("Nothing to report. Yet.")
                    .font(.ui(14, .medium))
                    .foregroundStyle(Palette.muted)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(cards.prefix(4)) { card in
                            HighlightCardView(card: card, compact: true)
                                .frame(width: 184)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - POOPING button

/// One tap starts a timed session, two taps log instantly. The press feedback is immediate;
/// the single-tap commit waits a quarter second to see whether a second tap follows.
struct PoopingButton: View {
    var onLog: (_ timed: Bool) -> Void
    @State private var pending: Task<Void, Never>?
    @State private var bump = false

    var body: some View {
        Button {
            if let p = pending {
                p.cancel()
                pending = nil
                fire(timed: false)
            } else {
                Haptics.tick()
                pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 260_000_000)
                    guard !Task.isCancelled else { return }
                    pending = nil
                    fire(timed: true)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text("POOP NOW")
                    .font(.display(29))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 18, weight: .black))
            }
            .foregroundStyle(Palette.paper)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
        }
        .buttonStyle(StickerButtonStyle(fill: Palette.ink, ink: Palette.paper, radius: 26, height: 76, font: .display(29), fullWidth: true, shadow: 3))
        .scaleEffect(bump ? 1.025 : 1)
        .animation(Motion.slam, value: bump)
        .accessibilityLabel("Poop now")
        .accessibilityHint("Tap to start a timed session. Double tap to log instantly.")
        .accessibilityAction(named: "Log instantly") { fire(timed: false) }
    }

    private func fire(timed: Bool) {
        bump = true
        onLog(timed)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            bump = false
        }
    }
}

// MARK: - Friend cloud

/// Friends stay visually calm while idle. Live state earns color and motion.
struct FriendCloud: View {
    @Environment(AppModel.self) private var model
    var friends: [FriendSummary]
    var showAdd: () -> Void

    var body: some View {
        if friends.isEmpty {
            Button(action: showAdd) {
                HStack(spacing: 12) {
                    HStack(spacing: -10) {
                        ForEach(0..<3, id: \.self) { i in
                            AvatarView(spec: AvatarSpec(shape: AvatarSpec.Shape.allCases[i % 5], tone: i * 3, eyes: AvatarSpec.Eyes.allCases[i + 1], mouth: AvatarSpec.Mouth.allCases[i], accessory: .none), color: [IdentityColor.hotPink, .electric, .lime][i], size: 44)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ADD FRIENDS").font(.heading(13)).foregroundStyle(Palette.ink)
                        Text("QR, link or AirDrop").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 15, weight: .black)).foregroundStyle(Palette.ink)
                }
                .padding(12)
                .calmSurface(Palette.card, radius: 20)
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("FRIENDS")
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(friends) { f in
                            NavigationLink {
                                FriendDetailView(userID: f.person.id)
                            } label: {
                                FriendBubble(summary: f)
                                    .frame(width: 72)
                            }
                            .buttonStyle(PressableStyle())
                        }
                        Button(action: showAdd) {
                            VStack(spacing: 7) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(Palette.paper2))
                                Text("ADD").font(.heading(9)).foregroundStyle(Palette.muted)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct FriendBubble: View {
    var summary: FriendSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if summary.live != nil {
                    Circle()
                        .stroke(summary.person.color.color, lineWidth: 4)
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulse && !reduceMotion ? 1.08 : 1)
                        .opacity(pulse && !reduceMotion ? 0.45 : 1)
                        .animation(reduceMotion ? .default : .easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: pulse)
                }
                AvatarView(person: summary.person, size: 56)
                if summary.live != nil {
                    Circle()
                        .fill(Palette.ink)
                        .frame(width: 22, height: 22)
                        .overlay(Text("💩").font(.system(size: 12)))
                        .offset(x: 22, y: -20)
                }
            }
            HandleText(handle: summary.person.handle, size: 10)
            if let live = summary.live {
                TimerText(start: live.startedAt, size: 11, color: Palette.ink)
            } else {
                Text("\(summary.todayCount) today")
                    .font(.ui(10, .bold))
                    .foregroundStyle(Palette.muted)
                    .contentTransition(.numericText(value: Double(summary.todayCount)))
            }
        }
        .scaleEffect(bounce ? 1.08 : 1)
        .onAppear { pulse = summary.live != nil }
        .onChange(of: summary.live != nil) { _, isLive in pulse = isLive }
        .onChange(of: summary.todayCount) { _, _ in
            withAnimation(Motion.slam) { bounce = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                withAnimation(Motion.snappy) { bounce = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("@\(summary.person.handle), \(summary.live != nil ? "currently pooping" : "\(summary.todayCount) today")")
    }
}

// MARK: - Bits

struct InviteCard: View {
    var emoji: String
    var title: String
    var subtitle: String
    var fill: Color
    var action: String
    var primary: () -> Void
    var secondary: (() -> Void)?

    init(emoji: String, title: String, subtitle: String, fill: Color, action: String, primary: @escaping () -> Void, secondary: (() -> Void)?) {
        self.emoji = emoji
        self.title = title
        self.subtitle = subtitle
        self.fill = fill
        self.action = action
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(fill).frame(width: 38, height: 38)
                Text(emoji).font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.heading(11)).foregroundStyle(Palette.ink).lineLimit(2)
                Text(subtitle).font(.ui(11, .medium)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 2)
            if let secondary {
                Button(action: secondary) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .black)).foregroundStyle(Palette.muted)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Not now")
            }
            Button(action, action: primary)
                .font(.heading(10))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Capsule().fill(Palette.ink))
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(action): \(title)")
        }
        .padding(10)
        .calmSurface(Palette.card, radius: 18)
    }
}

struct InfoBanner: View {
    var text: String
    var fill: Color = Palette.paper2

    var body: some View {
        Text(text)
            .font(.ui(12, .semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .calmSurface(fill, radius: 15, outlined: false)
    }
}

struct UndoBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let u = model.store.undo, context.date.timeIntervalSince(u.at) < Store.undoWindow, !model.showSession {
                HStack {
                    Text(u.source == .timed ? "TIMER STARTED" : "LOGGED +1").font(.heading(12)).foregroundStyle(Palette.paper)
                    Spacer()
                    Button("UNDO") { withAnimation(Motion.snappy) { model.store.performUndo() } }
                        .font(.heading(11))
                        .foregroundStyle(Palette.inkFixed)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.sun))
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Capsule().fill(Palette.ink))
                .padding(.horizontal, 24)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Little poops that shoot up when you log.
struct FlyingPoops: View {
    var trigger: Int
    var cosmetic: CosmeticID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bursts: [Burst] = []

    struct Burst: Identifiable {
        let id = UUID()
        var x: CGFloat
        var rotation: Double
        var flying = false
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(bursts) { b in
                    Object3DImage(subject: .poop(cosmetic), size: 44)
                        .rotationEffect(.degrees(b.flying ? b.rotation : 0))
                        .position(x: geo.size.width / 2 + (b.flying ? b.x : 0), y: b.flying ? -60 : geo.size.height * 0.72)
                        .opacity(b.flying ? 0 : 1)
                }
            }
        }
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            let new = (0..<5).map { _ in Burst(x: CGFloat.random(in: -150...150), rotation: Double.random(in: -240...240)) }
            bursts.append(contentsOf: new)
            let ids = Set(new.map(\.id))
            withAnimation(.easeOut(duration: 1.1)) {
                for i in bursts.indices where ids.contains(bursts[i].id) { bursts[i].flying = true }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                bursts.removeAll { ids.contains($0.id) }
            }
        }
    }
}
