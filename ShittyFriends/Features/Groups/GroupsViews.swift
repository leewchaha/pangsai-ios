import SwiftUI
import UIKit

struct GroupsView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var newParty = false

    private var store: Store { model.store }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("GROUPS")
                        .font(.display(40))
                        .foregroundStyle(Palette.ink)
                    Text("Group members see what you share in the group. Full history stays between friends.")
                        .font(.ui(14, .medium))
                        .foregroundStyle(Palette.muted)

                    HStack(spacing: 12) {
                        Button { creating = true } label: { Label("NEW GROUP", systemImage: "plus") }
                            .buttonStyle(.sticker(Palette.pink, ink: .white))
                        Button {
                            if let text = UIPasteboard.general.string { model.handle(text: text) } else { model.info("CLIPBOARD EMPTY", "Copy the group invite link first.") }
                        } label: { Label("JOIN", systemImage: "link") }
                            .buttonStyle(.sticker(Palette.card, ink: Palette.ink))
                    }

                    let parties = store.parties()
                    if !parties.isEmpty {
                        SectionTitle("UPCOMING POOP PARTIES", trailing: "+ NEW") { newParty = true }
                        ForEach(parties) { p in
                            NavigationLink { PartyDetailView(partyID: p.party.id) } label: { PartyRow(view: p) }
                                .buttonStyle(PressableStyle())
                        }
                    } else {
                        SectionTitle("POOP PARTIES", trailing: "+ SCHEDULE") { newParty = true }
                    }

                    SectionTitle("YOUR GROUPS · \(store.groupSummaries.count)")
                    if store.groupSummaries.isEmpty {
                        EmptyState(emoji: "🚽", title: "NO GROUPS YET", message: "Make one for The Boys, your dorm, your class trip. Share the link; anyone with it can join.")
                    }
                    ForEach(store.groupSummaries) { g in
                        NavigationLink { GroupDetailView(groupID: g.link.id) } label: { GroupCard(group: g) }
                            .buttonStyle(PressableStyle())
                    }
                }
                .gutter()
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh() }
            .sheet(isPresented: $creating) { CreateGroupView().environment(model) }
            .sheet(isPresented: $newParty) { CreatePartyView(group: nil).environment(model) }
        }
    }
}

struct GroupCard: View {
    @Environment(AppModel.self) private var model
    var group: GroupSummary

    var body: some View {
        let board = model.store.leaderboard(group.link.zone)
        let total = board.reduce(0) { $0 + $1.count }
        let live = group.members.filter { m in model.store.cache.zones[group.link.zone]?.events.values.contains { $0.ownerID == m.id && $0.isLive } ?? false }
        HStack(spacing: 14) {
            Object3DImage(subject: .group(group.object), size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name.uppercased()).font(.heading(18)).foregroundStyle(group.color.ink).lineLimit(1)
                Text("\(group.members.count) members · \(total) this week").font(.ui(13, .semibold)).foregroundStyle(group.color.ink.opacity(0.8))
                if !live.isEmpty {
                    Text("💩 " + live.map { group.labels[$0.id] ?? "@" + $0.person.handle }.joined(separator: ", ") + " pooping now")
                        .font(.ui(12, .bold))
                        .foregroundStyle(group.color.ink)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: -12) {
                ForEach(group.members.prefix(3)) { m in AvatarView(person: m.person, size: 34) }
            }
        }
        .padding(14)
        .sticker(group.color.color, radius: 22, shadow: 5)
    }
}

// MARK: - Create / join

struct CreateGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var object: GroupObject = .toilet
    @State private var color: IdentityColor = .hotPink
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Object3DImage(subject: .group(object), size: 150)
                        .padding(.top, 10)
                    TextField("THE BOYS", text: $name)
                        .font(.display(26))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .padding(14)
                        .sticker(Palette.card, radius: 18, shadow: 4)
                    SectionTitle("ICON")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                        ForEach(GroupObject.allCases, id: \.self) { o in
                            Button { object = o; Haptics.tick() } label: {
                                Object3DImage(subject: .group(o), size: 50)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(o == object ? Palette.sun : Color.clear))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(o == object ? Palette.line : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    SectionTitle("COLOR")
                    ColorRow(selection: $color)
                    Button(working ? "MAKING IT…" : "CREATE GROUP") {
                        working = true
                        Task {
                            if await model.createGroup(name: name, object: object, color: color) != nil {
                                dismiss()
                            }
                            working = false
                        }
                    }
                    .buttonStyle(.sticker(color.color, ink: color.ink, height: 62))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                .gutter()
                .padding(.bottom, 24)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("NEW GROUP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ColorRow: View {
    @Binding var selection: IdentityColor

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(IdentityColor.allCases, id: \.self) { c in
                Button { selection = c; Haptics.tick() } label: {
                    Circle()
                        .fill(c.color)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(Palette.line, lineWidth: c == selection ? 4 : 2))
                        .scaleEffect(c == selection ? 1.12 : 1)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(c.displayName)
            }
        }
    }
}

struct GroupJoinConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var offer: GroupJoinOffer

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Object3DImage(subject: .group(offer.object), size: 140)
            Text("JOIN \(offer.name.uppercased())?")
                .font(.display(26))
                .multilineTextAlignment(.center)
            Text("Members will see the poops you share to this group, live sessions and the leaderboard.\n\nGroup membership is not friendship: they can't open your full history unless you're also shitty friends.")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("JOIN GROUP") {
                dismiss()
                Task { await model.joinGroup(offer) }
            }
            .buttonStyle(.sticker(Palette.pink, ink: .white, height: 64))
            Button("NOT NOW") {
                model.groupOffers[offer.id] = nil
                dismiss()
            }
            .font(.heading(14))
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}

// MARK: - Detail

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var groupID: UUID
    @State private var period: HighlightPeriod = .week
    @State private var inviteURL: URL?
    @State private var showInvite = false
    @State private var newParty = false
    @State private var pwmPicker = false
    @State private var confirmLeave = false

    private var store: Store { model.store }

    var body: some View {
        if let g = store.group(groupID) {
            content(g)
        } else {
            EmptyState(emoji: "🫥", title: "GROUP GONE", message: "You left, or the owner deleted it.")
        }
    }

    private func content(_ g: GroupSummary) -> some View {
        let board = store.leaderboard(g.link.zone, period: period)
        let total = board.reduce(0) { $0 + $1.count }
        let cards = store.groupHighlightCards(g.link.zone, period: period)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    Object3DImage(subject: .group(g.object), size: 120)
                    Text(g.name.uppercased()).font(.display(30)).multilineTextAlignment(.center).foregroundStyle(g.color.ink)
                    Text("\(total) poops \(period == .week ? "this week" : period == .month ? "this month" : "today"). \(HighlightsEngine.totalCopy(total: total, isGroup: true))")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(g.color.ink.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .sticker(g.color.color, radius: 28, shadow: 6)

                HStack(spacing: 12) {
                    Button {
                        Task {
                            do {
                                inviteURL = try await model.groupInviteURL(groupID)
                                showInvite = true
                            } catch {
                                model.error("No invite link", error)
                            }
                        }
                    } label: { Label("INVITE", systemImage: "qrcode") }
                        .buttonStyle(.sticker(Palette.sun))
                    Button {
                        if store.liveEvent == nil {
                            model.info("START POOPING FIRST", "Poop With Me starts from a live session.")
                        } else {
                            pwmPicker = true
                        }
                    } label: { Label("POOP WITH", systemImage: "person.3.fill") }
                        .buttonStyle(.sticker(Palette.pink, ink: .white))
                }

                Picker("Period", selection: $period) {
                    Text("TODAY").tag(HighlightPeriod.day)
                    Text("THIS WEEK").tag(HighlightPeriod.week)
                    Text("THIS MONTH").tag(HighlightPeriod.month)
                }
                .pickerStyle(.segmented)

                SectionTitle("LEADERBOARD")
                VStack(spacing: 0) {
                    ForEach(board.indices, id: \.self) { i in
                        let member = board[i].member
                        LeaderRow(rank: i, label: g.labels[member.id] ?? "@" + member.person.handle, person: member.person, count: board[i].count, isMe: member.id == store.userID)
                        if i < board.count - 1 { Divider().overlay(Palette.line.opacity(0.2)) }
                    }
                    HStack {
                        Text("TOTAL").font(.heading(14))
                        Spacer()
                        Text("\(total) 💩").font(.digits(20))
                    }
                    .padding(.top, 10)
                }
                .foregroundStyle(Palette.ink)
                .padding(14)
                .sticker(Palette.card)

                if !cards.isEmpty {
                    SectionTitle(period.title)
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(cards) { c in HighlightCardView(card: c, compact: true).frame(width: 210) }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                }

                let trophies = store.groupAchievements(g.link.zone)
                SectionTitle("GROUP TROPHIES · \(trophies.filter(\.earned).count)/\(trophies.count)")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(trophies) { t in
                            VStack(spacing: 6) {
                                Object3DImage(subject: .trophy(t.id.object), size: 64, locked: !t.earned)
                                Text(t.id.title.uppercased())
                                    .font(.heading(10))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Text(t.earned ? "EARNED" : t.id.detail)
                                    .font(.ui(10, .medium))
                                    .foregroundStyle(t.earned ? Palette.inkFixed.opacity(0.7) : Palette.muted)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                            }
                            .foregroundStyle(t.earned ? Palette.inkFixed : Palette.ink)
                            .frame(width: 104)
                            .padding(.vertical, 10)
                            .sticker(t.earned ? Palette.sun : Palette.card, radius: 18, shadow: 3, stroke: 2)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)

                let parties = store.parties().filter { $0.zone == g.link.zone }
                SectionTitle("POOP PARTIES", trailing: "+ SCHEDULE") { newParty = true }
                if parties.isEmpty {
                    Text("Nothing scheduled. Suspicious.").font(.ui(14, .medium)).foregroundStyle(Palette.muted)
                }
                ForEach(parties) { p in
                    NavigationLink { PartyDetailView(partyID: p.party.id) } label: { PartyRow(view: p) }
                        .buttonStyle(PressableStyle())
                }

                SectionTitle("MEMBERS · \(g.members.count)")
                ForEach(g.members) { m in
                    HStack(spacing: 12) {
                        AvatarView(person: m.person, size: 42)
                        VStack(alignment: .leading, spacing: 1) {
                            HandleText(handle: g.labels[m.id] ?? m.person.handle, size: 15)
                            Text(m.role == .owner ? "owner" : (m.id == store.userID ? "you" : (store.isFriend(m.id) ? "shitty friend" : "group member")))
                                .font(.ui(12, .medium))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if g.link.isOwner && m.id != store.userID {
                            Menu {
                                Button("Remove from group", role: .destructive) {
                                    Task { await model.removeMember(groupID, member: m) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Member options")
                        }
                    }
                }

                SectionTitle("SETTINGS")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Notifications", selection: Binding(get: { g.link.notify }, set: { store.setGroupPrefs(groupID, notify: $0) })) {
                        ForEach(GroupNotifyLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Share my poops here", isOn: Binding(get: { g.link.shareEvents }, set: { store.setGroupPrefs(groupID, shareEvents: $0) }))
                    Toggle("Include locations", isOn: Binding(get: { g.link.shareLocations }, set: { store.setGroupPrefs(groupID, shareLocations: $0) }))
                        .disabled(!g.link.shareEvents)
                }
                .font(.ui(15, .semibold))
                .foregroundStyle(Palette.ink)
                .padding(14)
                .sticker(Palette.card, radius: 18, shadow: 3, stroke: 2)

                Button(g.link.isOwner ? "DELETE GROUP" : "LEAVE GROUP", role: .destructive) { confirmLeave = true }
                    .buttonStyle(.sticker(Palette.tomato, ink: .white, height: 50))
                    .confirmationDialog(g.link.isOwner ? "Delete \(g.name) for everyone?" : "Leave \(g.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                        Button(g.link.isOwner ? "Delete" : "Leave", role: .destructive) {
                            model.leaveGroup(groupID)
                            dismiss()
                        }
                    } message: {
                        Text(g.link.isOwner ? "You created this group, so it ends for all members." : "Your shared poops are removed from the group.")
                    }
            }
            .gutter()
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.cloud.fetch(zone: g.link.zone) }
        .onAppear { model.startPolling(g.link.zone, every: 15) }
        .onDisappear { model.stopPolling(g.link.zone) }
        .sheet(isPresented: $showInvite) {
            if let url = inviteURL { GroupInviteSheet(name: g.name, url: url).environment(model) }
        }
        .sheet(isPresented: $newParty) { CreatePartyView(group: g).environment(model) }
        .sheet(isPresented: $pwmPicker) {
            GroupPWMSheet(group: g).environment(model)
        }
    }
}

struct LeaderRow: View {
    var rank: Int
    var label: String
    var person: PersonRef
    var count: Int
    var isMe: Bool

    private var medal: String {
        guard count > 0 else { return " " }
        switch rank {
        case 0: return "👑"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return " "
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(medal)
                .font(.system(size: 22))
                .frame(width: 30)
            AvatarView(person: person, size: 34)
            HandleText(handle: label, size: 15)
            if isMe { Text("YOU").font(.heading(9)).padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Palette.sun)).foregroundStyle(Palette.inkFixed) }
            Spacer()
            Text("\(count)").font(.digits(22))
        }
        .padding(.vertical, 8)
    }
}

struct GroupInviteSheet: View {
    var name: String
    var url: URL

    var body: some View {
        VStack(spacing: 18) {
            Text("INVITE TO\n\(name.uppercased())").font(.display(26)).multilineTextAlignment(.center)
            QRCodeView(text: url.absoluteString, size: 220)
            ShareLink(item: url, message: Text(DeepLinkCodec.groupShareText(name: name, url: url))) {
                Label("SHARE LINK", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.sticker(Palette.sun))
            Text("Anyone with this link can join the group. Joining doesn't make them your friend.")
                .font(.ui(13, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
        .presentationDetents([.large])
    }
}

/// Start (or extend) Poop With Me inside a group.
struct GroupPWMSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var group: GroupSummary
    @State private var selected = Set<UserID>()

    var body: some View {
        let others = group.members.filter { $0.id != model.store.userID }
        NavigationStack {
            List(others) { m in
                Button {
                    if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(m.id) ? "circle.inset.filled" : "circle").font(.system(size: 22, weight: .bold))
                        AvatarView(person: m.person, size: 40)
                        HandleText(handle: group.labels[m.id] ?? m.person.handle, size: 16)
                    }
                    .foregroundStyle(Palette.ink)
                }
                .listRowBackground(Palette.paper)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.paper.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button("INVITE \(selected.count)") {
                    let people = others.filter { selected.contains($0.id) }.map(\.person)
                    if let live = model.store.liveEvent, let sid = live.pwmSessionID, let view = model.store.liveSession(sid), view.zone == group.link.zone {
                        Task { await model.inviteMore(view, people: people); dismiss() }
                    } else if model.startPWM(group: group, invitees: people) != nil {
                        dismiss()
                        model.presentSession(afterDismissal: true)
                    }
                }
                .buttonStyle(.sticker(Palette.pink, ink: .white, height: 60))
                .disabled(selected.isEmpty)
                .gutter()
                .padding(.vertical, 10)
            }
            .navigationTitle("POOP WITH \(group.name.uppercased())")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { selected = Set(others.map(\.id)) }
        }
    }
}
