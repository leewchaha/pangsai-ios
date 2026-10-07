import SwiftUI

struct PartyRow: View {
    var view: PartyView

    var body: some View {
        let yes = view.rsvps.filter { $0.response == .yes }.count
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(view.party.scheduledAt.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.heading(10))
                Text(view.party.scheduledAt.formatted(.dateTime.day())).font(.digits(24))
            }
            .foregroundStyle(Palette.inkFixed)
            .frame(width: 54, height: 58)
            .sticker(Palette.tangerine, radius: 14, shadow: 3, stroke: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(view.party.title.uppercased()).font(.heading(15)).lineLimit(1)
                Text(view.party.scheduledAt.shortTime + (view.groupName.map { " · " + $0 } ?? "") + " · \(yes) going")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
            Spacer()
            if view.party.isJoinable(now: Date()) {
                Text("LIVE").font(.heading(11)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Palette.tomato))
            }
        }
        .padding(10)
        .sticker(Palette.card, radius: 18, shadow: 3, stroke: 2)
    }
}

struct PartyDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var partyID: UUID
    @State private var confirmCancel = false

    private var store: Store { model.store }

    var body: some View {
        if let p = store.party(partyID) {
            content(p)
        } else {
            EmptyState(emoji: "🎈", title: "PARTY NOT FOUND", message: "It may have been cancelled or it's still syncing.")
                .task { await model.refresh() }
        }
    }

    private func content(_ p: PartyView) -> some View {
        let mine = store.myRSVP(p)
        return ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("🚨").font(.system(size: 54))
                    Text(p.party.title.uppercased()).font(.display(28)).multilineTextAlignment(.center)
                    Text(p.party.scheduledAt.formatted(.dateTime.weekday(.wide).hour().minute()).uppercased())
                        .font(.heading(16))
                    if let g = p.groupName { Text(g.uppercased()).font(.heading(12)).foregroundStyle(Palette.inkFixed.opacity(0.7)) }
                    if p.party.status == .cancelled {
                        Text("CANCELLED").font(.heading(14)).foregroundStyle(.white).padding(8).background(Capsule().fill(Palette.tomato))
                    } else if p.party.scheduledAt > Date() {
                        Text(p.party.scheduledAt, style: .relative)
                            .font(.digits(20))
                    }
                }
                .foregroundStyle(Palette.inkFixed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .sticker(Palette.tangerine, radius: 28, shadow: 6)

                if p.party.status == .scheduled {
                    if p.party.isJoinable(now: Date()) {
                        if mine?.joinedAt == nil {
                            Button("JOIN 💩") {
                                dismiss()
                                model.joinParty(p, afterDismissal: true)
                            }
                            .buttonStyle(.sticker(Palette.sun, height: 70))
                            Text("JOIN means you're actually pooping now. +1, timer starts.")
                                .font(.ui(13, .medium))
                                .foregroundStyle(Palette.muted)
                        } else {
                            Text("YOU'RE IN. 🫡").font(.heading(18))
                        }
                    } else if !p.party.isOver(now: Date()) {
                        HStack(spacing: 10) {
                            ForEach(RSVPResponse.allCases, id: \.self) { r in
                                Button {
                                    store.rsvp(zone: p.zone, partyID: p.party.id, response: r)
                                    Haptics.tick()
                                } label: {
                                    Text(r == .yes ? "✓ IN" : r == .maybe ? "? MAYBE" : "✕ OUT")
                                }
                                .buttonStyle(StickerButtonStyle(fill: mine?.response == r ? Palette.sun : Palette.card, ink: mine?.response == r ? Palette.inkFixed : Palette.ink, radius: 16, height: 50, font: .heading(14)))
                            }
                        }
                        Text("Nobody is ever forced to join.").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("GUEST LIST")
                    ForEach(p.rsvps) { r in
                        HStack(spacing: 12) {
                            AvatarView(person: r.person, size: 40)
                            HandleText(handle: r.person.handle, size: 15)
                            Spacer()
                            if r.joinedAt != nil {
                                Text("💩 IN").font(.heading(13))
                            } else {
                                Text(r.response.symbol).font(.heading(20))
                            }
                        }
                        .foregroundStyle(Palette.ink)
                    }
                }
                .padding(14)
                .sticker(Palette.card)

                if p.party.creatorID == store.userID && p.party.status == .scheduled && !p.party.isOver(now: Date()) {
                    Button("CANCEL PARTY", role: .destructive) { confirmCancel = true }
                        .buttonStyle(.sticker(Palette.tomato, ink: .white, height: 50))
                        .confirmationDialog("Cancel this Poop Party?", isPresented: $confirmCancel, titleVisibility: .visible) {
                            Button("Cancel party", role: .destructive) { store.cancelParty(zone: p.zone, partyID: p.party.id) }
                        }
                }
            }
            .foregroundStyle(Palette.ink)
            .gutter()
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startPolling(p.zone, every: 10) }
        .onDisappear { model.stopPolling(p.zone) }
    }
}

struct CreatePartyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var group: GroupSummary?

    @State private var title = "Poop Party"
    @State private var date = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 22, minute: 30), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
    @State private var targetGroup: UUID?
    @State private var friends = Set<UserID>()
    @State private var working = false

    private var store: Store { model.store }

    var body: some View {
        NavigationStack {
            Form {
                Section("WHAT") {
                    TextField("Title", text: $title)
                }
                Section("WHEN") {
                    DatePicker("Time", selection: $date, in: Date()...)
                }
                if group == nil {
                    Section("WHO") {
                        Picker("Invite", selection: $targetGroup) {
                            Text("Pick friends").tag(UUID?.none)
                            ForEach(store.groupSummaries) { g in Text(g.name).tag(UUID?.some(g.link.id)) }
                        }
                        if targetGroup == nil {
                            ForEach(store.friendSummaries()) { f in
                                Button {
                                    if friends.contains(f.person.id) { friends.remove(f.person.id) } else { friends.insert(f.person.id) }
                                } label: {
                                    HStack {
                                        Image(systemName: friends.contains(f.person.id) ? "checkmark.circle.fill" : "circle")
                                        AvatarView(person: f.person, size: 30)
                                        Text("@" + f.person.handle)
                                    }
                                }
                                .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                } else if let g = group {
                    Section("WHO") {
                        Text("Everyone in \(g.name) (\(g.members.count))")
                    }
                }
                Section {
                    Text("Everyone gets a reminder 5 minutes before. JOIN at party time counts as a poop and starts your timer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CREATE POOP PARTY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "…" : "SCHEDULE") { schedule() }
                        .bold()
                        .disabled(working || !canSchedule)
                }
            }
        }
    }

    private var canSchedule: Bool {
        if group != nil || targetGroup != nil { return true }
        return !friends.isEmpty
    }

    private func schedule() {
        working = true
        let chosenGroup = group ?? targetGroup.flatMap { store.group($0) }
        let people = store.friendSummaries().filter { friends.contains($0.person.id) }.map(\.person)
        Task {
            if await model.createParty(title: title, at: date, group: chosenGroup, friends: people) != nil {
                dismiss()
            }
            working = false
        }
    }
}
