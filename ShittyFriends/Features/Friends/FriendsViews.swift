import SwiftUI
import UIKit

// MARK: - Friends list

struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var reviewing: IncomingFriendRequest?

    private var store: Store { model.store }

    var body: some View {
        let friends = store.friendSummaries()
        let pending = store.pendingFriendLinks
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    showAdd = true
                } label: {
                    Label("ADD SHITTY FRIENDS", systemImage: "plus")
                }
                .buttonStyle(.sticker(Palette.aqua))

                if !store.friendRequests.isEmpty {
                    SectionTitle("REQUESTS")
                    ForEach(store.friendRequests) { req in
                        Button { reviewing = req } label: {
                            HStack(spacing: 12) {
                                AvatarView(person: req.person, size: 50)
                                VStack(alignment: .leading, spacing: 2) {
                                    HandleText(handle: req.person.handle, size: 17, color: Palette.inkFixed)
                                    Text("wants to be shitty friends").font(.ui(13, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.7))
                                }
                                Spacer()
                                Text("REVIEW").font(.heading(12)).foregroundStyle(Palette.inkFixed)
                            }
                            .padding(12)
                            .sticker(Palette.sun, radius: 18, shadow: 4)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }

                if !pending.isEmpty {
                    SectionTitle("PENDING")
                    ForEach(pending) { link in
                        HStack(spacing: 12) {
                            if let p = link.person { AvatarView(person: p, size: 44) }
                            VStack(alignment: .leading, spacing: 2) {
                                HandleText(handle: link.person?.handle ?? "someone", size: 15)
                                Text(link.status == .requested ? "Request sent. Waiting for them to accept." : "Accepted. Finishing the handshake…")
                                    .font(.ui(12, .medium))
                                    .foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button("CANCEL") { store.cancelPendingLink(link.id) }
                                .font(.heading(11))
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(12)
                        .sticker(Palette.card, radius: 16, shadow: 3, stroke: 2)
                    }
                }

                if !friends.isEmpty {
                    let board = store.friendLeaderboard(period: .week)
                    SectionTitle("THIS WEEK")
                    VStack(spacing: 0) {
                        ForEach(board.indices, id: \.self) { i in
                            let row = board[i]
                            LeaderRow(rank: i, label: "@" + row.person.handle, person: row.person, count: row.count, isMe: row.person.id == store.userID)
                            if i < board.count - 1 { Divider().overlay(Palette.line.opacity(0.2)) }
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(14)
                    .sticker(Palette.card)
                }

                SectionTitle("FRIENDS · \(friends.count)")
                if friends.isEmpty {
                    EmptyState(emoji: "🧻", title: "NO SHITTY FRIENDS YET", message: "Send your invite link or show your QR. They confirm, you confirm, histories unlock.")
                } else {
                    ForEach(friends) { f in
                        NavigationLink {
                            FriendDetailView(userID: f.person.id)
                        } label: {
                            FriendRow(summary: f)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .gutter()
            .padding(.vertical, 12)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle("SHITTY FRIENDS")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) { AddFriendsView().environment(model) }
        .sheet(item: $reviewing) { req in
            FriendRequestReviewView(request: req).environment(model)
        }
        .refreshable { await model.refresh() }
    }
}

struct FriendRow: View {
    var summary: FriendSummary

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(person: summary.person, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                HandleText(handle: summary.person.handle, size: 17)
                if let live = summary.live {
                    HStack(spacing: 4) {
                        Text("💩 CURRENTLY POOPING ·").font(.heading(11))
                        TimerText(start: live.startedAt, size: 12, color: Palette.ink)
                    }
                    .foregroundStyle(Palette.ink)
                } else if let last = summary.lastEvent {
                    Text("last: " + last.startedAt.formatted(.relative(presentation: .named)))
                        .font(.ui(12, .medium))
                        .foregroundStyle(Palette.muted)
                } else if !summary.hasHistory {
                    Text("syncing their history…").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            VStack(spacing: 0) {
                Text("\(summary.todayCount)").font(.digits(24)).foregroundStyle(Palette.ink)
                Text("TODAY").font(.heading(9)).foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .sticker(Palette.card, radius: 18, shadow: 4)
    }
}

// MARK: - Add friends

struct AddFriendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("ADD YOUR\nSHITTY FRIENDS")
                        .font(.display(30))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.ink)
                    Text("No usernames, no search. Share your link or QR. They tap it, you accept, histories unlock both ways.")
                        .font(.ui(14, .medium))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)

                    Group {
                        if let url {
                            QRCodeView(text: url.absoluteString, size: 210)
                        } else if let error {
                            InfoBanner(text: error, fill: Palette.paper2)
                        } else {
                            ProgressView().frame(width: 238, height: 238)
                        }
                    }

                    if let url {
                        ShareLink(item: url, message: Text(model.friendInviteText(url))) {
                            Label("SHARE INVITE LINK", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.sticker(Palette.sun))
                    }

                    HStack(spacing: 12) {
                        Button {
                            scanning = true
                        } label: {
                            Label("SCAN", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.sticker(Palette.card, ink: Palette.ink))
                        .disabled(!QRScannerView.isAvailable)

                        Button {
                            if let text = UIPasteboard.general.string {
                                dismiss()
                                model.afterDismissal { $0.handle(text: text) }
                            } else {
                                model.info("CLIPBOARD EMPTY", "Copy their invite message first.")
                            }
                        } label: {
                            Label("PASTE", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.sticker(Palette.card, ink: Palette.ink))
                    }

                    Button("Reset my invite link") {
                        model.store.revokeInvites()
                        url = nil
                        Task { await load() }
                    }
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Palette.muted)
                    Text("Invites expire after 7 days. Anyone holding one can only *request* — you still accept.")
                        .font(.ui(12, .medium))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .gutter()
                .padding(.vertical, 16)
            }
            .background(Palette.paper.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
            .sheet(isPresented: $scanning) {
                ZStack(alignment: .top) {
                    QRScannerView { text in
                        scanning = false
                        dismiss()
                        model.afterDismissal { $0.handle(text: text) }
                    }
                    .ignoresSafeArea()
                    Text("SCAN A SHITTYFRIENDS QR")
                        .font(.heading(14))
                        .foregroundStyle(Palette.inkFixed)
                        .padding(12)
                        .sticker(Palette.sun, radius: 14, shadow: 3)
                        .padding(.top, 20)
                }
            }
        }
    }

    private func load() async {
        do {
            url = try await model.friendInviteURL()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Confirmations

/// B side: tapped someone's invite.
struct FriendInviteConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var invite: FriendInvitePayload

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AvatarView(spec: invite.avatar, color: invite.color, size: 120)
            Text("BECOME SHITTY FRIENDS\nWITH @\(invite.h.uppercased())?")
                .font(.display(24))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink)
            Text("@\(invite.h) will be able to see your full poop history, including older entries and shared poop locations. You'll see theirs.")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("SEND REQUEST") {
                model.sendFriendRequest(invite)
                dismiss()
            }
            .buttonStyle(.sticker(Palette.aqua, height: 64))
            Button("NOT NOW") { dismiss() }
                .font(.heading(14))
                .foregroundStyle(Palette.ink)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}

/// A side: someone answered my invite.
struct FriendRequestReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: IncomingFriendRequest

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AvatarView(person: request.person, size: 120)
            Text("BECOME SHITTY FRIENDS?")
                .font(.display(26))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink)
            Text("@\(request.person.handle) will be able to see your full poop history, including older entries and shared poop locations.")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("ACCEPT") {
                dismiss()
                Task { await model.acceptFriendRequest(request) }
            }
            .buttonStyle(.sticker(Palette.lime, height: 64))
            HStack(spacing: 24) {
                Button("DECLINE") {
                    model.declineFriendRequest(request, block: false)
                    dismiss()
                }
                Button("BLOCK") {
                    model.declineFriendRequest(request, block: true)
                    dismiss()
                }
                .foregroundStyle(Palette.tomato)
            }
            .font(.heading(14))
            .foregroundStyle(Palette.ink)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}

// MARK: - Friend detail

struct FriendDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var userID: UserID
    @State private var confirmRemove = false

    private var store: Store { model.store }

    var body: some View {
        let summary = store.friendSummaries().first { $0.person.id == userID }
        let events = store.friendEvents(userID)
        let cache = store.friendCache(userID)
        ScrollView {
            if let s = summary {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        AvatarView(person: s.person, size: 110)
                        HandleText(handle: s.person.handle, size: 28)
                        if let live = s.live {
                            HStack(spacing: 6) {
                                Text("💩 CURRENTLY POOPING").font(.heading(13))
                                TimerText(start: live.startedAt, size: 15, color: Palette.inkFixed)
                            }
                            .foregroundStyle(Palette.inkFixed)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .sticker(Palette.sun, radius: 14, shadow: 3)
                        }
                    }
                    .padding(.top, 8)

                    let stats = StatsCalculator.compute(events, now: Date(), calendar: store.calendar)
                    let week = StatsCalculator.compute(events, in: CalendarMath.weekInterval(Date(), calendar: store.calendar), now: Date(), calendar: store.calendar)
                    HStack(spacing: 10) {
                        StatTile(value: "\(s.todayCount)", label: "TODAY", fill: s.person.color.color)
                        StatTile(value: "\(week.total)", label: "THIS WEEK", fill: Palette.card)
                        StatTile(value: "\(stats.currentStreak)", label: "STREAK", fill: Palette.card)
                    }

                    NavigationLink {
                        CalendarScreen(subject: .friend(userID))
                    } label: {
                        Label("@\(s.person.handle.uppercased())'S CALENDAR", systemImage: "calendar")
                            .font(.heading(15))
                            .foregroundStyle(Palette.inkFixed)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .sticker(Palette.lime, radius: 20, shadow: 4)
                    }
                    .buttonStyle(PressableStyle())

                    if let c = cache, !c.achievements.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("TROPHIES")
                            ScrollView(.horizontal) {
                                HStack(spacing: 10) {
                                    ForEach(c.achievements.values.sorted { $0.unlockedAt > $1.unlockedAt }) { a in
                                        VStack(spacing: 4) {
                                            Object3DImage(subject: .trophy(a.id.object), size: 64)
                                            Text(a.id.title.uppercased()).font(.heading(9)).lineLimit(2).multilineTextAlignment(.center).frame(width: 80)
                                        }
                                        .foregroundStyle(Palette.ink)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    if let c = cache, !c.cosmetics.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("POOP COLLECTION · \(c.cosmetics.count + 1)")
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach([CosmeticID.classic] + c.cosmetics.keys.sorted { $0.price < $1.price }, id: \.self) { id in
                                        Object3DImage(subject: .poop(id), size: 56)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    let link = s.link
                    Group {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("NOTIFY ME")
                            Picker("Notify", selection: Binding(get: { link.notify }, set: { store.setFriendNotify(link.id, $0) })) {
                                ForEach(FriendNotifyLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }

                        Button("REMOVE FRIEND", role: .destructive) { confirmRemove = true }
                            .buttonStyle(.sticker(Palette.tomato, ink: .white, height: 50))
                            .confirmationDialog("Remove @\(s.person.handle)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                                Button("Remove", role: .destructive) {
                                    Task { await model.removeFriend(link) }
                                    dismiss()
                                }
                                Button("Remove and block", role: .destructive) {
                                    Task { await model.blockFriend(link) }
                                    dismiss()
                                }
                            } message: {
                                Text("They immediately lose access to your history (and you to theirs).")
                            }
                    }
                }
                .gutter()
                .padding(.bottom, 30)
            } else {
                EmptyState(emoji: "👻", title: "NOT FRIENDS", message: "This friendship ended or is still syncing.")
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var fill: Color = Palette.card

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.digits(26)).lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.heading(9)).tracking(0.5)
        }
        .foregroundStyle(fill == Palette.card ? Palette.ink : Palette.inkFixed)
        .frame(maxWidth: .infinity, minHeight: 74)
        .sticker(fill, radius: 18, shadow: 4)
    }
}
