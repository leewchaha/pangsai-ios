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
                BlobBackground(colors: [store.profile.color.color] + friends.prefix(4).map { $0.person.color.color })
                ScrollView {
                    VStack(spacing: 22) {
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
                    .padding(.top, 8)
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.display(40))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(Date().formatted(.dateTime.day().month(.wide)).uppercased())
                    .font(.heading(13))
                    .tracking(2)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { showFriends = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Palette.inkFixed)
                        .frame(width: 52, height: 52)
                        .sticker(Palette.aqua, radius: 18, shadow: 4)
                    if requests > 0 {
                        Text("\(requests)")
                            .font(.heading(12))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(Palette.tomato))
                            .overlay(Circle().strokeBorder(Palette.line, lineWidth: 2))
                            .offset(x: 8, y: -8)
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
        let joinable = store.parties().filter { $0.party.isJoinable(now: Date()) && store.myRSVP($0)?.joinedAt == nil }
        if !invites.isEmpty || !joinable.isEmpty || !store.friendRequests.isEmpty {
            VStack(spacing: 12) {
                ForEach(invites) { v in
                    let host = v.participants.first(where: { $0.id == v.session.creatorID })?.person ?? store.person(for: v.session.creatorID)
                    InviteCard(emoji: "💩", title: "@\(host?.handle ?? "someone") WANTS TO POOP WITH YOU", subtitle: v.groupName ?? "Poop With Me", fill: Palette.pink, action: "JOIN", primary: {
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SlamNumber(value: today, size: 64)
            VStack(alignment: .leading, spacing: 0) {
                Text("TODAY").font(.heading(18)).foregroundStyle(Palette.ink)
                Text(Copy.todayLine(count: today, seed: today + Calendar.current.component(.day, from: Date())))
                    .font(.ui(14, .medium))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            let streak = store.stats().currentStreak
            if streak >= 2 {
                VStack(spacing: 0) {
                    Text("🔥 \(streak)").font(.heading(18))
                    Text("DAY STREAK").font(.heading(9)).foregroundStyle(Palette.muted)
                }
                .foregroundStyle(Palette.ink)
            }
        }
    }

    // MARK: POOPING

    @ViewBuilder private var poopingArea: some View {
        if let live = store.liveEvent {
            Button { model.showSession = true } label: {
                VStack(spacing: 8) {
                    Text("CURRENTLY POOPING").font(.heading(16)).foregroundStyle(Palette.inkFixed)
                    TimerText(start: live.startedAt, size: 54, color: Palette.inkFixed)
                    Text("TAP TO OPEN").font(.heading(11)).foregroundStyle(Palette.inkFixed.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .sticker(Palette.sun, radius: 28, shadow: 6)
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(spacing: 12) {
                ZStack {
                    PoopStageView(cosmetic: store.profile.equippedCosmetic, pulse: launch, hdr: true)
                        .frame(height: 210)
                    if let flash = instantFlash {
                        Text(flash)
                            .font(.heading(16))
                            .foregroundStyle(Palette.inkFixed)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .sticker(Palette.lime, radius: 14, shadow: 3)
                            .transition(.scale.combined(with: .opacity))
                            .offset(y: -70)
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
                Text("TAP = TIMER  ·  DOUBLE TAP = INSTANT")
                    .font(.heading(10))
                    .tracking(1)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Highlights

    @ViewBuilder private var highlightsStrip: some View {
        let cards = store.highlightCards(period: .day)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("TODAY IN SHIT", trailing: "THE WEEK →") { showWeek = true }
            if cards.isEmpty {
                Text("Nothing to report. Yet.")
                    .font(.ui(15, .medium))
                    .foregroundStyle(Palette.muted)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(cards) { card in
                            HighlightCardView(card: card, compact: true)
                                .frame(width: 210)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
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
            Text("POOPING")
                .font(.display(38))
                .foregroundStyle(Palette.inkFixed)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
        }
        .buttonStyle(StickerButtonStyle(fill: Palette.sun, ink: Palette.inkFixed, radius: 30, height: 96, font: .display(38)))
        .scaleEffect(bump ? 1.06 : 1)
        .animation(Motion.slam, value: bump)
        .accessibilityLabel("Pooping")
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

/// Friends as floating bubbles in an asymmetric, gently bobbing layout (not a feed).
struct FriendCloud: View {
    @Environment(AppModel.self) private var model
    var friends: [FriendSummary]
    var showAdd: () -> Void

    var body: some View {
        if friends.isEmpty {
            Button(action: showAdd) {
                VStack(spacing: 10) {
                    HStack(spacing: -14) {
                        ForEach(0..<3, id: \.self) { i in
                            AvatarView(spec: AvatarSpec(shape: AvatarSpec.Shape.allCases[i % 5], tone: i * 3, eyes: AvatarSpec.Eyes.allCases[i + 1], mouth: AvatarSpec.Mouth.allCases[i], accessory: .none), color: [IdentityColor.hotPink, .electric, .lime][i], size: 54)
                        }
                    }
                    Text("ADD YOUR SHITTY FRIENDS").font(.heading(17)).foregroundStyle(Palette.inkFixed)
                    Text("QR, link, AirDrop. No usernames to search. Ever.").font(.ui(13, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .sticker(Palette.aqua)
            }
            .buttonStyle(PressableStyle())
        } else {
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(friends.enumerated()), id: \.element.id) { i, f in
                    NavigationLink {
                        FriendDetailView(userID: f.person.id)
                    } label: {
                        FriendBubble(summary: f)
                            .offset(y: i % 3 == 1 ? 18 : (i % 2 == 0 ? 0 : -6))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.bottom, 14)
        }
    }
}

struct FriendBubble: View {
    var summary: FriendSummary
    @State private var bob = false
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if summary.live != nil {
                    Circle()
                        .stroke(summary.person.color.color, lineWidth: 5)
                        .frame(width: 80, height: 80)
                        .scaleEffect(bob ? 1.12 : 0.96)
                        .opacity(bob ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bob)
                }
                AvatarView(person: summary.person, size: 66)
                if summary.live != nil {
                    Text("💩")
                        .font(.system(size: 24))
                        .offset(x: 26, y: -24)
                }
            }
            HandleText(handle: summary.person.handle, size: 12)
            if let live = summary.live {
                TimerText(start: live.startedAt, size: 13, color: Palette.ink)
            } else {
                Text("💩 \(summary.todayCount)")
                    .font(.heading(13))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: Double(summary.todayCount)))
            }
        }
        .scaleEffect(bounce ? 1.15 : 1)
        .offset(y: bob && summary.live == nil ? -3 : 0)
        .animation(.easeInOut(duration: 2.2 + Double(abs(summary.person.handle.hashValue % 10)) / 10).repeatForever(autoreverses: true), value: bob)
        .onAppear { bob = true }
        .onChange(of: summary.todayCount) { _, _ in
            withAnimation(Motion.slam) { bounce = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(Motion.bouncy) { bounce = false }
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
        HStack(spacing: 12) {
            Text(emoji).font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.heading(13)).foregroundStyle(Palette.inkFixed).lineLimit(2)
                Text(subtitle).font(.ui(12, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.75)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let secondary {
                Button(action: secondary) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .black)).foregroundStyle(Palette.inkFixed)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Not now")
            }
            Button(action, action: primary)
                .buttonStyle(StickerButtonStyle(fill: .white, ink: Palette.inkFixed, radius: 14, height: 40, font: .heading(13), fullWidth: false))
        }
        .padding(12)
        .sticker(fill, radius: 20, shadow: 4)
    }
}

struct InfoBanner: View {
    var text: String
    var fill: Color = Palette.paper2

    var body: some View {
        Text(text)
            .font(.ui(13, .semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .sticker(fill, radius: 16, shadow: 3, stroke: 2)
    }
}

struct UndoBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let u = model.store.undo, context.date.timeIntervalSince(u.at) < Store.undoWindow, !model.showSession {
                HStack {
                    Text(u.source == .timed ? "TIMER STARTED" : "LOGGED +1").font(.heading(13)).foregroundStyle(.white)
                    Spacer()
                    Button("UNDO") { withAnimation(Motion.snappy) { model.store.performUndo() } }
                        .font(.heading(13))
                        .foregroundStyle(Palette.inkFixed)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Palette.sun))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Palette.inkFixed))
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
