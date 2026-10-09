import SceneKit
import SwiftUI

struct YouView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var period: HighlightPeriod = .week
    @State private var showStats = false
    @State private var showTrophies = false
    @State private var showCollection = false

    private var store: Store { model.store }

    var body: some View {
        let p = store.profile
        let all = store.stats()
        let interval = period.interval(containing: Date(), calendar: store.calendar)
        let s = store.stats(in: interval)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileHeader(p)
                    quickLinks

                    Picker("Period", selection: $period) {
                        Text("TODAY").tag(HighlightPeriod.day)
                        Text("WEEK").tag(HighlightPeriod.week)
                        Text("MONTH").tag(HighlightPeriod.month)
                    }
                    .pickerStyle(.segmented)

                    statSnapshot(s: s, all: all, accent: p.color)

                    Button {
                        withAnimation(Motion.snappy) { showStats.toggle() }
                    } label: {
                        RevealRow(title: "ALL STATS", detail: showStats ? "HIDE" : "VIEW", symbol: "chart.bar.fill", expanded: showStats, accent: p.color.color)
                    }
                    .buttonStyle(PressableStyle())

                    if showStats {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            StatTile(value: "\(s.total)", label: "POOPS", fill: p.color.color)
                            StatTile(value: "\(s.activeDays)", label: "ACTIVE DAYS")
                            StatTile(value: String(format: "%.1f", s.averagePerActiveDay), label: "PER DAY")
                            StatTile(value: s.commonWindowLabel.map { String($0.prefix(5)) } ?? "—", label: "PRIME TIME")
                            StatTile(value: s.longestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "LONGEST")
                            StatTile(value: s.shortestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "FASTEST")
                            StatTile(value: "\(s.pwmCount)", label: "POOP WITH ME")
                            StatTile(value: "\(s.partyCount)", label: "PARTIES")
                            StatTile(value: "\(all.currentStreak)🔥", label: "CURRENT STREAK")
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))

                        if let place = all.mostUsedPlace {
                            InfoBanner(text: "📍 All-time most-used throne: \(place) · \(all.uniquePlaces) places · \(all.countries) countries", fill: Palette.paper2)
                        }
                        Text("Stats are for fun, not medical advice.")
                            .font(.ui(11, .medium))
                            .foregroundStyle(Palette.muted)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.sheet = .highlights(period, Date())
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text(period.title).font(.heading(13))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundStyle(Palette.paper)
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.ink))
                        }
                        .buttonStyle(PressableStyle())

                        Button {
                            model.sheet = .profilePoster
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.square")
                                Text("PROFILE POSTER").font(.heading(12))
                            }
                            .foregroundStyle(Palette.ink)
                            .frame(width: 146, height: 50)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
                        }
                        .buttonStyle(PressableStyle())
                    }

                    Button {
                        withAnimation(Motion.snappy) { showTrophies.toggle() }
                    } label: {
                        RevealRow(title: "TROPHY ROOM", detail: "\(store.my.achievements.count)/\(AchievementID.allCases.count)", symbol: "trophy.fill", expanded: showTrophies, accent: Palette.sun)
                    }
                    .buttonStyle(PressableStyle())
                    if showTrophies {
                        TrophyRoom()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button {
                        withAnimation(Motion.snappy) { showCollection.toggle() }
                    } label: {
                        RevealRow(title: "COLLECTION", detail: "POOPS + PIN SHINES", symbol: "shippingbox.fill", expanded: showCollection, accent: Palette.violet)
                    }
                    .buttonStyle(PressableStyle())
                    if showCollection {
                        CollectionSection()
                        PinShineCollectionSection()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .gutter()
                .padding(.top, 14)
                .padding(.bottom, 28)
                // Tapping empty space (between cards) folds the open sections away.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard showStats || showTrophies || showCollection else { return }
                            withAnimation(Motion.snappy) {
                                showStats = false
                                showTrophies = false
                                showCollection = false
                            }
                        }
                }
            }
            .scrollIndicators(.hidden)
            .clearsTabBar()
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $editing) { EditProfileView().environment(model) }
        }
    }

    private func profileHeader(_ p: UserProfile) -> some View {
        HStack(spacing: 14) {
            AvatarView(spec: p.avatar, color: p.color, size: 76)
            VStack(alignment: .leading, spacing: 5) {
                HandleText(handle: p.handle, size: 22)
                HStack(spacing: 7) {
                    Text("\(formatPoints(store.pointsBalance)) PTS")
                        .font(.heading(11))
                        .foregroundStyle(Palette.inkFixed)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.sun))
                        .accessibilityLabel("\(formatPoints(store.pointsBalance)) points")
                    Button {
                        editing = true
                    } label: {
                        Text("EDIT")
                            .font(.heading(10))
                            .foregroundStyle(Palette.muted)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Edit profile")
                }
            }
            Spacer()
            NavigationLink { SettingsView() } label: {
                Object3DImage(subject: .poop(p.equippedCosmetic), size: 62)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Settings")
            .accessibilityHint("Open app settings")
        }
    }

    private var quickLinks: some View {
        NavigationLink { FriendsView() } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.paper2))
                Text("FRIENDS")
                    .font(.heading(12))
                Spacer()
                Text("\(store.activeFriendLinks.count)")
                    .font(.digits(15))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .calmSurface(Palette.card, radius: 17)
        }
        .buttonStyle(PressableStyle())
    }

    private func statSnapshot(s: PoopStats, all: PoopStats, accent: IdentityColor) -> some View {
        HStack(spacing: 0) {
            SnapshotMetric(value: "\(s.total)", label: "POOPS", accent: accent.color)
            Divider().frame(height: 34)
            SnapshotMetric(value: "\(all.currentStreak)🔥", label: "CURRENT STREAK", accent: Palette.sun)
            Divider().frame(height: 34)
            SnapshotMetric(value: "\(s.uniquePlaces)", label: "PLACES", accent: Palette.aqua)
        }
        .padding(.vertical, 12)
        .calmSurface(Palette.card, radius: 20)
    }
}

struct SnapshotMetric: View {
    var value: String
    var label: String
    var accent: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.digits(23)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.55)
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(label).font(.heading(9.5)).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct RevealRow: View {
    var title: String
    var detail: String
    var symbol: String
    var expanded: Bool
    var accent: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Palette.inkFixed)
                .frame(width: 34, height: 34)
                .background(Circle().fill(accent))
            Text(title).font(.heading(12)).foregroundStyle(Palette.ink)
            Spacer()
            Text(detail).font(.ui(11, .bold)).foregroundStyle(Palette.muted)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(10)
        .calmSurface(Palette.card, radius: 17)
        .accessibilityElement(children: .combine)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

// MARK: - Trophies

struct TrophyRoom: View {
    @Environment(AppModel.self) private var model
    @State private var detail: AchievementID?

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("TROPHY ROOM · \(store.my.achievements.count)/\(AchievementID.allCases.count)")
            ForEach(AchievementCategory.allCases, id: \.self) { cat in
                let items = AchievementID.allCases.filter { $0.category == cat }
                Text(cat.title).font(.heading(11)).tracking(1.5).foregroundStyle(Palette.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(items) { a in
                        let unlocked = store.my.achievements[a] != nil
                        Button { detail = a } label: {
                            VStack(spacing: 4) {
                                Object3DImage(subject: .trophy(a.object), size: 70, locked: !unlocked)
                                Text(a.title.uppercased()).font(.heading(9)).multilineTextAlignment(.center).lineLimit(2)
                                    .foregroundStyle(unlocked ? Palette.ink : Palette.muted)
                                if !unlocked, let prog = store.achievementProgress(a) {
                                    ProgressView(value: prog.fraction).tint(Palette.pink).frame(width: 60)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .sticker(unlocked ? Palette.sun.opacity(0.35) : Palette.card, radius: 18, shadow: 3, stroke: 2)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(trophyLabel(a, unlocked: unlocked))
                    }
                }
            }
        }
        .sheet(item: $detail) { a in TrophyDetail(id: a).environment(model).presentationDetents([.medium]) }
    }

    private func trophyLabel(_ a: AchievementID, unlocked: Bool) -> String {
        if unlocked { return "\(a.title), unlocked" }
        if let p = model.store.achievementProgress(a) { return "\(a.title), locked, \(p.current) of \(p.target)" }
        return "\(a.title), locked"
    }
}

struct TrophyDetail: View {
    @Environment(AppModel.self) private var model
    var id: AchievementID

    var body: some View {
        let unlock = model.store.my.achievements[id]
        VStack(spacing: 12) {
            PoopTrophyStage(object: id.object)
                .frame(height: 200)
                .saturation(unlock == nil ? 0 : 1)
            Text(id.title.uppercased()).font(.display(24))
            Text(id.detail).font(.ui(15, .medium)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            if let u = unlock {
                Text("UNLOCKED " + u.unlockedAt.formatted(date: .abbreviated, time: .omitted).uppercased()).font(.heading(12))
                if let city = u.metadata["city"] { Text("📍 " + city).font(.ui(13, .semibold)) }
            } else if let p = model.store.achievementProgress(id) {
                Text("\(p.current) / \(p.target)").font(.digits(22))
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}

/// Live spinning trophy (3D) for detail sheets.
struct PoopTrophyStage: UIViewRepresentable {
    var object: TrophyObject

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.isUserInteractionEnabled = false
        let node = TrophyFactory.node(object)
        let (scene, camera) = Stage.make(subject: node)
        v.scene = scene
        v.pointOfView = camera
        v.isPlaying = true
        node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 8)))
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - Collection / shop

struct CollectionSection: View {
    @Environment(AppModel.self) private var model
    @State private var preview: CosmeticID?

    var body: some View {
        let store = model.store
        let owned = Set(store.ownedCosmetics)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("POOP COLLECTION · \(owned.count)/\(CosmeticID.allCases.count)")
            Text("Tap the poop during a timed session: every tap pays 1 point, no limit. The rare ones take a while on purpose. Deleting a poop never takes points back.")
                .font(.ui(12, .medium))
                .foregroundStyle(Palette.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CosmeticID.allCases) { c in
                    let has = owned.contains(c)
                    let equipped = store.profile.equippedCosmetic == c
                    Button { preview = c } label: {
                        VStack(spacing: 4) {
                            Object3DImage(subject: .poop(c), size: 72, locked: !has && store.pointsBalance < c.price)
                            Text(c.displayName.replacingOccurrences(of: " Poop", with: "").uppercased()).font(.heading(9)).lineLimit(1)
                            Text(equipped ? "EQUIPPED" : has ? "OWNED" : "\(formatPoints(c.price)) PTS")
                                .font(.heading(9))
                                .foregroundStyle(equipped ? Palette.inkFixed : Palette.ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(equipped ? Palette.sun : Color.clear))
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 124)
                        .sticker(Palette.rarity(c.rarity).opacity(has ? 0.45 : 0.15), radius: 18, shadow: 3, stroke: 2)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .sheet(item: $preview) { c in CosmeticDetail(id: c).environment(model).presentationDetents([.medium, .large]) }
    }
}

struct CosmeticDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var id: CosmeticID
    @State private var pulse = 0
    @State private var confirmSpend = false

    var body: some View {
        let store = model.store
        let has = store.ownedCosmetics.contains(id)
        VStack(spacing: 12) {
            PoopStageView(cosmetic: id, pulse: pulse)
                .frame(height: 230)
                .contentShape(Rectangle())
                .onTapGesture { pulse += 1; Haptics.play(.tapLight) }
            Text(id.rarity.displayName).font(.heading(11)).tracking(2).foregroundStyle(Palette.rarityInk(id.rarity))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Palette.rarity(id.rarity)))
            Text(id.displayName.uppercased()).font(.display(24))
            Text(id.tagline).font(.ui(15, .medium)).foregroundStyle(Palette.muted)
            if has {
                Button(store.profile.equippedCosmetic == id ? "EQUIPPED" : "EQUIP") {
                    store.equip(id)
                    dismiss()
                }
                .buttonStyle(.sticker(Palette.sun))
                .disabled(store.profile.equippedCosmetic == id)
            } else {
                Button("UNLOCK · \(formatPoints(id.price)) PTS") {
                    if store.pointsBalance >= id.price {
                        confirmSpend = true
                    } else {
                        model.info("NOT YET", "\(formatPoints(id.price - store.pointsBalance)) more points. Keep tapping in future sessions.")
                    }
                }
                // A locked item still needs legible ink on the card surface (adaptive, not fixed dark).
                .buttonStyle(.sticker(store.pointsBalance >= id.price ? Palette.lime : Palette.card, ink: store.pointsBalance >= id.price ? Palette.inkFixed : Palette.ink))
                Text("Balance: \(formatPoints(store.pointsBalance)) points").font(.ui(13, .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
        .confirmationDialog("Unlock \(id.displayName)?", isPresented: $confirmSpend, titleVisibility: .visible) {
            Button("Spend \(formatPoints(id.price)) PTS") {
                do {
                    try model.store.purchase(id)
                    model.store.equip(id)
                    dismiss()
                } catch Store.PurchaseError.insufficientPoints(let needed) {
                    model.info("NOT YET", "\(formatPoints(needed)) more points needed.")
                } catch {
                    model.info("ALREADY YOURS", "")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have \(formatPoints(model.store.pointsBalance)) PTS. It's equipped right away.")
        }
    }
}

// MARK: - Pin shines (a separate collection sharing the same points balance)

struct PinShineCollectionSection: View {
    @Environment(AppModel.self) private var model
    @State private var preview: PinShineID?

    var body: some View {
        let store = model.store
        let owned = Set(store.ownedPinShines)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("PIN SHINES · \(owned.count)/\(PinShineID.allCases.count)")
            Text("Shines appear only when someone taps your poop pin on the map.")
                .font(.ui(12, .medium))
                .foregroundStyle(Palette.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(PinShineID.allCases) { shine in
                    let has = owned.contains(shine)
                    let equipped = store.profile.equippedPinShine == shine
                    Button { preview = shine } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle().fill(Palette.inkFixed.opacity(0.88))
                                    .frame(width: 60, height: 60)
                                PinShineEffect(id: shine, animated: false)
                                    .frame(width: 60, height: 60)
                                    .clipShape(Circle())
                                // Previewed on the poop the map actually shows for me: my equipped one.
                                Object3DImage(subject: .poop(store.profile.equippedCosmetic), size: 34)
                            }
                            .opacity(has ? 1 : 0.75)
                            Text(shine.displayName.uppercased())
                                .font(.heading(10))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(equipped ? "EQUIPPED" : has ? "OWNED" : "\(formatPoints(shine.price)) PTS")
                                .font(.heading(9))
                                .foregroundStyle(Palette.muted)
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 112)
                        .calmSurface(Palette.card, radius: 18)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .sheet(item: $preview) { shine in
            PinShineDetail(id: shine)
                .environment(model)
                .presentationDetents([.medium, .large])
        }
    }
}

struct PinShineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var id: PinShineID
    @State private var confirmSpend = false

    var body: some View {
        let store = model.store
        let has = store.ownedPinShines.contains(id)
        VStack(spacing: 16) {
            ZStack {
                // Dark stage so light shines (white, gold) read on a light sheet too.
                Circle().fill(Palette.inkFixed.opacity(0.9)).frame(width: 160, height: 160)
                PinShineEffect(id: id).frame(width: 160, height: 160).clipShape(Circle())
                Object3DImage(subject: .poop(store.profile.equippedCosmetic), size: 96)
            }
            .frame(height: 170)
            Text(id.displayName.uppercased()).font(.display(22))
            Text(id.tagline).font(.ui(14, .medium)).foregroundStyle(Palette.muted)
            Text("Only visible when your map pin is selected")
                .font(.ui(11, .medium)).foregroundStyle(Palette.muted)
            if has {
                Button(store.profile.equippedPinShine == id ? "EQUIPPED" : "EQUIP") {
                    store.equipPinShine(id)
                    dismiss()
                }
                .buttonStyle(.sticker(Palette.sun))
                .disabled(store.profile.equippedPinShine == id)
            } else {
                Button("UNLOCK · \(formatPoints(id.price)) PTS") {
                    if store.pointsBalance >= id.price {
                        confirmSpend = true
                    } else {
                        model.info("NOT YET", "\(formatPoints(id.price - store.pointsBalance)) more points. Keep tapping in future sessions.")
                    }
                }
                .buttonStyle(.sticker(store.pointsBalance >= id.price ? Palette.lime : Palette.card, ink: store.pointsBalance >= id.price ? Palette.inkFixed : Palette.ink))
                Text("Balance: \(formatPoints(store.pointsBalance)) points")
                    .font(.ui(13, .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
        .confirmationDialog("Unlock \(id.displayName)?", isPresented: $confirmSpend, titleVisibility: .visible) {
            Button("Spend \(formatPoints(id.price)) PTS") {
                do {
                    try model.store.purchasePinShine(id)
                    model.store.equipPinShine(id)
                    dismiss()
                } catch Store.PurchaseError.insufficientPoints(let needed) {
                    model.info("NOT YET", "\(formatPoints(needed)) more points needed.")
                } catch {
                    model.info("ALREADY YOURS", "")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have \(formatPoints(model.store.pointsBalance)) PTS. It's equipped right away.")
        }
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var avatar = AvatarSpec()
    @State private var color: IdentityColor = .lime

    var body: some View {
        NavigationStack {
            ScrollView {
                ProfileEditor(handle: $handle, avatar: $avatar, color: $color)
                    .gutter()
                    .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("EDIT PROFILE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.store.updateProfile(handle: handle, avatar: avatar, color: color)
                        dismiss()
                    }
                    .bold()
                    .disabled(HandleRules.validate(handle) != nil)
                }
            }
            .onAppear {
                let p = model.store.profile
                handle = p.handle
                avatar = p.avatar
                color = p.color
            }
        }
    }
}

/// Handle + avatar builder + color. Shared by onboarding and profile editing.
struct ProfileEditor: View {
    @Binding var handle: String
    @Binding var avatar: AvatarSpec
    @Binding var color: IdentityColor

    var body: some View {
        VStack(spacing: 18) {
            // No tap-to-randomize: one stray tap used to wipe a hand-built face. 🎲 does it on purpose.
            AvatarView(spec: avatar, color: color, size: 150)
            Button("🎲 RANDOMIZE") { withAnimation(Motion.bouncy) { avatar = .random(); color = .random() } }
                .font(.heading(12))
                .foregroundStyle(Palette.ink)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Text("@").font(.display(24)).foregroundStyle(Palette.muted)
                    TextField("handle", text: $handle)
                        .font(.display(24))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: handle) { _, v in
                            let n = HandleRules.normalize(v)
                            if n != v { handle = n }
                        }
                }
                .padding(14)
                .sticker(Palette.card, radius: 18, shadow: 4)
                if let problem = HandleRules.validate(handle), !handle.isEmpty {
                    Text(problem.message).font(.ui(12, .semibold)).foregroundStyle(Palette.tomato)
                } else {
                    Text("Doesn't need to be unique. Your friends know who you are.")
                        .font(.ui(12, .medium))
                        .foregroundStyle(Palette.muted)
                }
            }

            PartPicker(title: "SHAPE", options: AvatarSpec.Shape.allCases, selection: $avatar.shape) { AvatarSpec(shape: $0, tone: avatar.tone, eyes: avatar.eyes, mouth: avatar.mouth, accessory: avatar.accessory) }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("TONE")
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(AvatarSpec.tones.indices, id: \.self) { i in
                            Button { avatar.tone = i; Haptics.tick() } label: {
                                Circle().fill(Color(hex: AvatarSpec.tones[i])).frame(width: 38, height: 38)
                                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: avatar.tone == i ? 4 : 2))
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("Tone \(i + 1)")
                            .accessibilityAddTraits(avatar.tone == i ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
            PartPicker(title: "EYES", options: AvatarSpec.Eyes.allCases, selection: $avatar.eyes) { AvatarSpec(shape: avatar.shape, tone: avatar.tone, eyes: $0, mouth: avatar.mouth, accessory: avatar.accessory) }
            PartPicker(title: "MOUTH", options: AvatarSpec.Mouth.allCases, selection: $avatar.mouth) { AvatarSpec(shape: avatar.shape, tone: avatar.tone, eyes: avatar.eyes, mouth: $0, accessory: avatar.accessory) }
            PartPicker(title: "EXTRA", options: AvatarSpec.Accessory.allCases, selection: $avatar.accessory) { AvatarSpec(shape: avatar.shape, tone: avatar.tone, eyes: avatar.eyes, mouth: avatar.mouth, accessory: $0) }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("YOUR COLOR")
                ColorRow(selection: $color)
            }
        }
    }
}

struct PartPicker<Option: Hashable>: View {
    var title: String
    var options: [Option]
    @Binding var selection: Option
    var preview: (Option) -> AvatarSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { o in
                        Button { selection = o; Haptics.tick() } label: {
                            AvatarView(spec: preview(o), color: o == selection ? .sun : .sky, size: 56)
                                .scaleEffect(o == selection ? 1.08 : 1)
                        }
                        .buttonStyle(PressableStyle())
                        // The avatar preview is decorative; VoiceOver needs the option's name.
                        .accessibilityLabel("\(title.capitalized): \(String(describing: o))")
                        .accessibilityAddTraits(o == selection ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }
}
