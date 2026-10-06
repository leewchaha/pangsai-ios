import SwiftUI

// MARK: - Picker

/// Choose friends or a group to poop with. JOIN on their side means "I am actually pooping now".
struct PWMPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Set when inviting more people to a running session.
    var existing: LiveSessionView?

    enum Mode: Hashable { case friends, group(UUID) }
    @State private var mode: Mode = .friends
    @State private var selected = Set<UserID>()

    private var store: Store { model.store }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if existing == nil && !store.groupSummaries.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            Button { mode = .friends; selected = [] } label: { Chip(text: "FRIENDS", selected: mode == .friends) }
                            ForEach(store.groupSummaries) { g in
                                Button {
                                    mode = .group(g.link.id)
                                    selected = Set(g.members.map(\.id).filter { $0 != store.userID })
                                } label: { Chip(text: g.name.uppercased(), selected: mode == .group(g.link.id)) }
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .gutter()
                        .padding(.vertical, 10)
                    }
                    .scrollIndicators(.hidden)
                }
                List {
                    ForEach(candidates, id: \.person.id) { c in
                        Button {
                            if selected.contains(c.person.id) { selected.remove(c.person.id) } else { selected.insert(c.person.id) }
                            Haptics.tick()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(c.person.id) ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Palette.ink)
                                AvatarView(person: c.person, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    HandleText(handle: c.label, size: 16)
                                    if let note = c.note {
                                        Text(note).font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Palette.paper)
                        .disabled(c.disabled)
                        .opacity(c.disabled ? 0.45 : 1)
                    }
                    if candidates.isEmpty {
                        EmptyState(emoji: "🫥", title: "NOBODY TO INVITE", message: "Add friends or join a group first.")
                            .listRowBackground(Palette.paper)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Button {
                    invite()
                } label: {
                    Text(selected.isEmpty ? "PICK SOMEONE" : "INVITE \(selected.count)")
                }
                .buttonStyle(.sticker(Palette.pink, ink: .white, height: 64))
                .disabled(selected.isEmpty)
                .gutter()
                .padding(.vertical, 12)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("POOP WITH ME")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    struct Candidate {
        var person: PersonRef
        var label: String
        var note: String?
        var disabled: Bool
    }

    private var candidates: [Candidate] {
        let me = store.userID
        let already = Set(existing?.participants.map(\.id) ?? [])
        // Inviting more into a group session: only that group's members.
        if let ex = existing, let gid = ex.session.groupID, let g = store.group(gid) {
            return g.members.filter { $0.id != me }.map { m in
                Candidate(person: m.person, label: g.labels[m.id] ?? m.person.handle, note: already.contains(m.id) ? "already in" : nil, disabled: already.contains(m.id))
            }
        }
        switch mode {
        case .friends:
            return store.friendSummaries().map { f in
                let busy = f.live != nil
                return Candidate(person: f.person, label: f.person.handle, note: already.contains(f.person.id) ? "already in" : (busy ? "currently pooping" : nil), disabled: already.contains(f.person.id))
            }
        case .group(let gid):
            guard let g = store.group(gid) else { return [] }
            return g.members.filter { $0.id != me }.map { m in
                Candidate(person: m.person, label: g.labels[m.id] ?? m.person.handle, note: nil, disabled: false)
            }
        }
    }

    private func invite() {
        let people = candidates.filter { selected.contains($0.person.id) }.map(\.person)
        guard !people.isEmpty else { return }
        if let ex = existing {
            Task {
                await model.inviteMore(ex, people: people)
                dismiss()
            }
            return
        }
        switch mode {
        case .friends:
            Task {
                if await model.startPWM(friends: people) != nil { dismiss() }
            }
        case .group(let gid):
            if let g = store.group(gid), model.startPWM(group: g, invitees: people) != nil { dismiss() }
        }
    }
}

// MARK: - Live panel (inside the session screen)

struct PWMLivePanel: View {
    @Environment(AppModel.self) private var model
    var view: LiveSessionView
    var inviteMore: () -> Void
    @State private var appearedAt = Date()

    var body: some View {
        let reactions = model.store.reactions(zone: view.zone, sessionID: view.session.id, since: appearedAt)
        VStack(spacing: 14) {
            HStack {
                Text("POOP WITH ME").font(.heading(15)).foregroundStyle(Palette.inkFixed)
                if let g = view.groupName {
                    Text("· \(g.uppercased())").font(.heading(12)).foregroundStyle(Palette.inkFixed.opacity(0.6))
                }
                Spacer()
                Button("+ INVITE", action: inviteMore)
                    .font(.heading(12))
                    .foregroundStyle(Palette.inkFixed)
            }
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(view.participants) { p in
                    ParticipantTile(participant: p, isMe: p.id == model.store.userID)
                }
            }
            HStack(spacing: 6) {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    Button {
                        model.store.sendReaction(zone: view.zone, sessionID: view.session.id, kind: kind)
                    } label: {
                        Text(kind.emoji)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.85)))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("React \(kind.rawValue)")
                }
            }
        }
        .padding(14)
        .sticker(Palette.pink.opacity(0.92), radius: 22, shadow: 4)
        .overlay { ReactionRain(reactions: reactions).allowsHitTesting(false) }
        .onAppear {
            appearedAt = Date().addingTimeInterval(-5)
            model.startPolling(view.zone)
        }
        .onDisappear { model.stopPolling(view.zone) }
    }
}

struct ParticipantTile: View {
    var participant: PWMParticipant
    var isMe: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(person: participant.person, size: 54)
                    .opacity(participant.status == .invited ? 0.5 : 1)
                if participant.status == .joined { Text("💩").font(.system(size: 18)) }
                if participant.status == .done { Text("✅").font(.system(size: 16)) }
            }
            HandleText(handle: isMe ? "you" : participant.person.handle, size: 11, color: Palette.inkFixed)
            Group {
                switch participant.status {
                case .joined:
                    if let s = participant.startedAt { TimerText(start: s, size: 14, color: Palette.inkFixed) }
                case .done:
                    if let s = participant.startedAt, let e = participant.endedAt {
                        Text("DONE · " + StatsCalculator.formatDuration(e.timeIntervalSince(s))).font(.heading(10))
                    } else {
                        Text("DONE").font(.heading(10))
                    }
                case .invited:
                    Text("INVITED…").font(.heading(10))
                case .declined:
                    Text("NOT NOW").font(.heading(10))
                }
            }
            .foregroundStyle(Palette.inkFixed)
        }
    }
}

/// New reactions launch upward across the panel with a spin.
struct ReactionRain: View {
    var reactions: [Reaction]
    @State private var shown = Set<UUID>()
    @State private var flying: [Flying] = []

    struct Flying: Identifiable {
        let id: UUID
        var emoji: String
        var x: CGFloat
        var launched = false
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(flying) { f in
                    Text(f.emoji)
                        .font(.system(size: 44))
                        .rotationEffect(.degrees(f.launched ? 200 : 0))
                        .scaleEffect(f.launched ? 1.4 : 0.6)
                        .position(x: geo.size.width * f.x, y: f.launched ? -40 : geo.size.height)
                        .opacity(f.launched ? 0 : 1)
                }
            }
        }
        .onChange(of: reactions.map(\.id)) { _, ids in
            let new = reactions.filter { !shown.contains($0.id) }
            guard !new.isEmpty else { return }
            for r in new {
                shown.insert(r.id)
                flying.append(Flying(id: r.id, emoji: r.kind.emoji, x: .random(in: 0.15...0.85)))
            }
            Haptics.play(.reaction)
            let newIDs = Set(new.map(\.id))
            withAnimation(.easeOut(duration: 1.4)) {
                for i in flying.indices where newIDs.contains(flying[i].id) { flying[i].launched = true }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                flying.removeAll { newIDs.contains($0.id) }
            }
            _ = ids
        }
    }
}

// MARK: - Incoming invite

struct PWMInviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var sessionID: UUID

    var body: some View {
        let view = model.store.liveSession(sessionID)
        let host = view.flatMap { v in v.participants.first(where: { $0.id == v.session.creatorID })?.person ?? model.store.person(for: v.session.creatorID) }
        VStack(spacing: 18) {
            Spacer()
            Object3DImage(subject: .poop(host?.cosmetic ?? .classic), size: 140)
            if let view {
                Text("@\(host?.handle ?? "someone")\nWANTS TO POOP WITH YOU")
                    .font(.display(26))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.inkFixed)
                if let g = view.groupName { Text(g.uppercased()).font(.heading(13)).foregroundStyle(Palette.inkFixed.opacity(0.7)) }
                HStack(spacing: -10) {
                    ForEach(view.participants.filter { $0.status == .joined }) { p in AvatarView(person: p.person, size: 46) }
                }
                Text("JOIN means you're actually pooping now. +1, timer starts.")
                    .font(.ui(14, .medium))
                    .foregroundStyle(Palette.inkFixed.opacity(0.8))
                    .multilineTextAlignment(.center)
                Spacer()
                Button("JOIN 💩") {
                    dismiss()
                    model.joinPWM(sessionID)
                }
                .buttonStyle(.sticker(Palette.sun, height: 70))
                Button("NOT NOW") {
                    model.store.declinePWM(zone: view.zone, sessionID: sessionID)
                    dismiss()
                }
                .font(.heading(14))
                .foregroundStyle(Palette.inkFixed)
            } else {
                Text("LOADING THE SESSION…").font(.heading(18)).foregroundStyle(Palette.inkFixed)
                Text("If this takes forever, the session may already be over.").font(.ui(14, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.7))
                Spacer()
                Button("CLOSE") { dismiss() }.buttonStyle(.sticker(.white))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.pink.ignoresSafeArea())
        .task {
            while model.store.liveSession(sessionID) == nil && !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
