import SceneKit
import SwiftUI

struct YouView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var period: HighlightPeriod = .week

    private var store: Store { model.store }

    var body: some View {
        let p = store.profile
        let all = store.stats()
        let interval = period.interval(containing: Date(), calendar: store.calendar)
        let s = store.stats(in: interval)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Identity
                    HStack(spacing: 16) {
                        AvatarView(spec: p.avatar, color: p.color, size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            HandleText(handle: p.handle, size: 26)
                            Text("\(store.pointsBalance) POINTS").font(.heading(13)).foregroundStyle(Palette.inkFixed)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Palette.sun))
                                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
                            Button("EDIT") { editing = true }
                                .font(.heading(12))
                                .foregroundStyle(Palette.ink)
                        }
                        Spacer()
                        Object3DImage(subject: .poop(p.equippedCosmetic), size: 74)
                    }

                    HStack(spacing: 10) {
                        NavigationLink { FriendsView() } label: {
                            Label("FRIENDS · \(store.activeFriendLinks.count)", systemImage: "person.2.fill")
                                .font(.heading(13)).foregroundStyle(Palette.inkFixed)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .sticker(Palette.aqua, radius: 16, shadow: 4)
                        }
                        NavigationLink { SettingsView() } label: {
                            Label("SETTINGS", systemImage: "gearshape.fill")
                                .font(.heading(13)).foregroundStyle(Palette.ink)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .sticker(Palette.card, radius: 16, shadow: 4)
                        }
                    }
                    .buttonStyle(PressableStyle())

                    // Stats
                    Picker("Period", selection: $period) {
                        Text("TODAY").tag(HighlightPeriod.day)
                        Text("WEEK").tag(HighlightPeriod.week)
                        Text("MONTH").tag(HighlightPeriod.month)
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatTile(value: "\(s.total)", label: "POOPS", fill: p.color.color)
                        StatTile(value: "\(s.activeDays)", label: "ACTIVE DAYS")
                        StatTile(value: String(format: "%.1f", s.averagePerActiveDay), label: "PER DAY")
                        StatTile(value: s.commonWindowLabel.map { String($0.prefix(5)) } ?? "—", label: "PRIME TIME")
                        StatTile(value: s.longestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "LONGEST")
                        StatTile(value: s.shortestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "FASTEST")
                        StatTile(value: "\(s.pwmCount)", label: "POOP WITH ME")
                        StatTile(value: "\(s.partyCount)", label: "PARTIES")
                        StatTile(value: "\(all.currentStreak)🔥", label: "STREAK")
                    }
                    if let place = all.mostUsedPlace {
                        InfoBanner(text: "📍 Most-used throne: \(place) · \(all.uniquePlaces) places · \(all.countries) countries", fill: Palette.paper2)
                    }
                    Text("Stats are for fun, not medical advice.")
                        .font(.ui(11, .medium))
                        .foregroundStyle(Palette.muted)

                    Button {
                        model.sheet = .highlights(period, Date())
                    } label: {
                        Label(period.title, systemImage: "sparkles")
                    }
                    .buttonStyle(.sticker(Palette.violet, ink: .white))

                    TrophyRoom()
                    CollectionSection()
                }
                .gutter()
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $editing) { EditProfileView().environment(model) }
        }
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
                    }
                }
            }
        }
        .sheet(item: $detail) { a in TrophyDetail(id: a).environment(model).presentationDetents([.medium]) }
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
            Text("Earn points by tapping during a timed session (capped per session and per day — pooping more doesn't help).")
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
                            Text(equipped ? "EQUIPPED" : has ? "OWNED" : "\(c.price) PTS")
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

    var body: some View {
        let store = model.store
        let has = store.ownedCosmetics.contains(id)
        VStack(spacing: 12) {
            PoopStageView(cosmetic: id, pulse: pulse)
                .frame(height: 230)
                .contentShape(Rectangle())
                .onTapGesture { pulse += 1; Haptics.play(.tapLight) }
            Text(id.rarity.displayName).font(.heading(11)).tracking(2).foregroundStyle(Palette.inkFixed)
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
                Button("UNLOCK · \(id.price) PTS") {
                    do {
                        try store.purchase(id)
                        store.equip(id)
                    } catch Store.PurchaseError.insufficientPoints(let needed) {
                        model.info("NOT YET", "\(needed) more points. Tap faster next time.")
                    } catch {
                        model.info("ALREADY YOURS", "")
                    }
                }
                .buttonStyle(.sticker(store.pointsBalance >= id.price ? Palette.lime : Palette.card, ink: Palette.inkFixed))
                Text("Balance: \(store.pointsBalance) points").font(.ui(13, .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
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
            AvatarView(spec: avatar, color: color, size: 150)
                .onTapGesture { withAnimation(Motion.bouncy) { avatar = .random() } }
                .accessibilityLabel("Avatar. Tap to randomize.")
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
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }
}
