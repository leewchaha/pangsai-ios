import CloudKit
import Foundation
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "social")

extension AppModel {
    enum SocialError: LocalizedError {
        case needsICloud
        case noLiveSession
        case nothingToJoin
        case badLink

        var errorDescription: String? {
            switch self {
            case .needsICloud: return "Sign in to iCloud (Settings › your name) to do this. Logging works without it."
            case .noLiveSession: return "Start pooping first."
            case .nothingToJoin: return "That session is over."
            case .badLink: return "That link isn't a ShittyFriends invite."
            }
        }
    }

    private func requireCloud() throws {
        guard availability.isAvailable, store.userID != nil else { throw SocialError.needsICloud }
    }

    private func withBusy<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        busy = label
        defer { busy = nil }
        return try await body()
    }

    // MARK: - Friend invites (A side)

    /// QR/share payload for my current invite. The invite itself is app data, not a CKShare.
    /// This avoids creating `cloudkit.share` just to show the Add Friends screen; CloudKit sharing is
    /// only needed later, after both people explicitly accept and history access is granted.
    func friendInviteURL() async throws -> URL {
        try requireCloud()
        let payload = store.friendInvitePayload()
        return DeepLinkCodec.friendURL(payload)
    }

    func friendInviteText(_ url: URL) -> String {
        DeepLinkCodec.friendShareText(handle: store.profile.handle, url: url)
    }

    /// A taps ACCEPT on a request: share my history with them, then tell them.
    func acceptFriendRequest(_ request: IncomingFriendRequest) async {
        do {
            try requireCloud()
            try await withBusy("Becoming shitty friends…") {
                let link = try store.acceptFriendRequest(request.id)
                guard let uid = link.userID else { return }
                let url = try await shares.shareMyHistory(with: uid)
                if let ping = PingPlanner.friendAccept(link: link, shareURL: url, store: store, now: Date()) {
                    pings.send([ping])
                }
                info("REQUEST ACCEPTED", "Waiting for @\(request.person.handle) to finish the handshake.")
            }
        } catch Store.HandshakeError.alreadyFriends {
            info("ALREADY FRIENDS", "@\(request.person.handle) is already a shitty friend.")
        } catch {
            self.error("Couldn't accept", error)
        }
    }

    func declineFriendRequest(_ request: IncomingFriendRequest, block: Bool) {
        store.dismissRequest(request.id)
        if block { store.block(request.person.id) }
    }

    // MARK: - Friend invites (B side)

    /// B confirmed "BECOME SHITTY FRIENDS?" on someone's invite.
    func sendFriendRequest(_ invite: FriendInvitePayload) {
        do {
            try requireCloud()
            let (_, ping) = try store.beginFriendRequest(invite)
            pings.send([ping])
            info("REQUEST SENT", "@\(invite.h) has to accept. Then your histories unlock.")
        } catch Store.HandshakeError.ownInvite {
            info("THAT'S YOU", "You can't befriend yourself. Emotionally, maybe.")
        } catch {
            self.error("Couldn't send request", error)
        }
    }

    // MARK: - Removing friends

    /// Unfriend: revoke their access to my history and leave theirs. Both sides end up clean.
    func removeFriend(_ link: FriendLink) async {
        let uid = link.userID
        store.removeFriendLocal(link.id)
        guard let uid else { return }
        await shares.unshareMyHistory(from: uid)
        shares.leave(ZoneRef(ownerName: uid, zoneName: ZoneNames.me))
    }

    func blockFriend(_ link: FriendLink) async {
        if let uid = link.userID { store.block(uid) }
        await removeFriend(link)
    }

    // MARK: - Incoming pings

    func processIncomingPings() async {
        guard availability.isAvailable, !processing else { return }
        processing = true
        defer { processing = false }
        let incoming = await pings.fetchIncoming()
        var needsSharedFetch = false
        for ping in incoming {
            let action = pings.process(ping)
            do {
                switch action {
                case .friendRequest(let req):
                    if store.receiveFriendRequest(req) {
                        show(Toast(style: .social, title: "FRIEND REQUEST", body: "@\(req.person.handle) wants to be shitty friends."))
                    }
                case .friendAccepted(let linkID, let person, let theirInbox, let url):
                    guard let shareURL = URL(string: url) else { break }
                    try await shares.accept(url: shareURL)
                    let myURL = try await shares.shareMyHistory(with: person.id)
                    try store.completeAsRequester(linkID: linkID, person: person, theirInbox: theirInbox, shareURL: url)
                    if let link = store.my.friendLinks[linkID], let p = PingPlanner.friendComplete(link: link, shareURL: myURL, store: store, now: Date()) {
                        pings.send([p])
                    }
                    show(Toast(style: .social, title: "SHITTY FRIENDS", body: "You and @\(person.handle) can see each other's history now."))
                case .friendCompleted(let linkID, let url):
                    guard let shareURL = URL(string: url) else { break }
                    try await shares.accept(url: shareURL)
                    try store.completeAsAccepter(linkID: linkID, shareURL: url)
                    let handle = store.my.friendLinks[linkID]?.person?.handle ?? "friend"
                    show(Toast(style: .social, title: "SHITTY FRIENDS", body: "Handshake complete with @\(handle)."))
                case .pwmInvite(let sessionID, _, let url):
                    if let url { try await joinSpace(url: url, kind: .pwm, expires: Date().addingTimeInterval(6 * 3600)) }
                    needsSharedFetch = true
                    if store.liveEvent == nil, sheet == nil, isForeground { sheet = .pwmInvite(sessionID) }
                case .partyInvite(_, _, let url):
                    if let url { try await joinSpace(url: url, kind: .party, expires: Date().addingTimeInterval(8 * 24 * 3600)) }
                    needsSharedFetch = true
                case .refreshShared:
                    needsSharedFetch = true
                case .ignore(let reason):
                    log.debug("ignored ping: \(reason, privacy: .public)")
                }
                pings.markProcessed(ping)
            } catch {
                // Leave unprocessed; it is retried on the next refresh until it expires.
                log.error("ping \(ping.kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if needsSharedFetch { await cloud.fetchShared() }
        // Parties may have just arrived: (re)schedule their reminders.
        for p in store.parties() where store.myRSVP(p)?.response != .no { notifications.scheduleParty(p, settings: store.settings) }
    }

    /// Accepts an ad-hoc session space shared by a friend and remembers it for cleanup.
    private func joinSpace(url: String, kind: SpaceKind, expires: Date) async throws {
        guard let u = URL(string: url) else { return }
        let accepted = try await shares.accept(url: u)
        if store.my.spaceLinks[accepted.zone] == nil {
            store.registerSpace(SpaceLink(zone: accepted.zone, kind: kind, isOwner: false, shareURL: url, participantIDs: [], expiresAt: expires))
        }
        await cloud.fetch(zone: accepted.zone)
    }

    /// Deletes (owner) or leaves (guest) session spaces that are past their expiry.
    func cleanupSpaces() {
        for space in store.expiredSpaces() {
            if space.isOwner { shares.deleteOwned(space.zone) } else { shares.leave(space.zone) }
            store.removeSpace(space.zone)
        }
    }

    // MARK: - Links (URLs, QR codes, system share acceptance)

    func handle(url: URL) {
        guard let link = DeepLinkCodec.parse(url) else {
            info("UNKNOWN LINK", "That isn't a ShittyFriends link.")
            return
        }
        switch link {
        case .friendInvite(let p):
            sheet = .friendInvite(p)
        case .groupInvite(let p):
            if let u = URL(string: p.u) { offerGroupJoin(GroupJoinOffer(name: p.n, color: p.color, object: p.object, metadata: nil, url: u)) }
        case .cloudShare(let u):
            Task { await openCloudShare(url: u) }
        case .openSession:
            if store.liveEvent != nil { showSession = true }
        case .openParty(let id):
            sheet = .party(id)
        }
    }

    /// Text pasted or scanned by the user.
    func handle(text: String) {
        if let link = DeepLinkCodec.find(in: text) {
            switch link {
            case .cloudShare(let u): Task { await openCloudShare(url: u) }
            case .friendInvite(let p): sheet = .friendInvite(p)
            case .groupInvite(let p):
                if let u = URL(string: p.u) { offerGroupJoin(GroupJoinOffer(name: p.n, color: p.color, object: p.object, metadata: nil, url: u)) }
            default: break
            }
        } else {
            info("NO LINK FOUND", "Copy the whole invite message and try again.")
        }
    }

    func openCloudShare(url: URL) async {
        do {
            try requireCloud()
            let metadata = try await withBusy("Opening invite…") { try await shares.metadataWithRoot(url) }
            await openCloudShare(metadata: metadata)
        } catch {
            self.error("Couldn't open link", error)
        }
    }

    /// Called for links the system opened for us (CKSharingSupported) and for pasted/scanned links.
    func openCloudShare(metadata: CKShare.Metadata) async {
        let zoneName = metadata.share.recordID.zoneID.zoneName
        do {
            try requireCloud()
            if zoneName == ZoneNames.invites {
                switch try await shares.readInviteCard(metadata) {
                case .invite(let p): sheet = .friendInvite(p)
                case .mine: info("THAT'S YOUR INVITE", "Send it to someone else.")
                case .notAnInvite: throw SocialError.badLink
                }
            } else if zoneName.hasPrefix(ZoneNames.groupPrefix) {
                let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "a group"
                offerGroupJoin(GroupJoinOffer(name: title, color: .violet, object: .toilet, metadata: metadata, url: metadata.share.url))
            } else if zoneName.hasPrefix(ZoneNames.sessionPrefix) {
                let accepted = try await shares.accept(metadata: metadata)
                if store.my.spaceLinks[accepted.zone] == nil {
                    store.registerSpace(SpaceLink(zone: accepted.zone, kind: .pwm, isOwner: false, shareURL: metadata.share.url?.absoluteString, expiresAt: Date().addingTimeInterval(6 * 3600)))
                }
                await cloud.fetch(zone: accepted.zone)
            } else if zoneName == ZoneNames.me {
                // A friend's history link: accepting is harmless; the handshake does the rest.
                try await shares.accept(metadata: metadata)
            } else {
                throw SocialError.badLink
            }
        } catch {
            self.error("Couldn't open invite", error)
        }
    }

    // MARK: - Groups

    private func offerGroupJoin(_ offer: GroupJoinOffer) {
        if let mine = store.my.groupLinks.values.first(where: { $0.shareURL != nil && $0.shareURL == offer.url?.absoluteString }) {
            info("ALREADY IN", "You're already in \(mine.nameCache).")
            return
        }
        groupOffers[offer.id] = offer
        sheet = .groupJoin(offer.id)
    }

    func createGroup(name: String, object: GroupObject, color: IdentityColor) async -> GroupLink? {
        do {
            try requireCloud()
            guard let link = store.createGroupLocal(name: name, object: object, color: color) else {
                info("PICK ANOTHER NAME", "Up to 28 characters, nothing offensive.")
                return nil
            }
            // The share link is created in the background; the group works locally right away.
            Task {
                do {
                    let url = try await shares.groupShareURL(zone: link.zone, name: link.nameCache)
                    store.setGroupShareURL(link.id, url)
                } catch {
                    self.error("Group link not ready", error)
                }
            }
            return link
        } catch {
            self.error("Couldn't create group", error)
            return nil
        }
    }

    func groupInviteURL(_ groupID: UUID) async throws -> URL {
        try requireCloud()
        guard let link = store.my.groupLinks[groupID] else { throw SocialError.badLink }
        if let s = link.shareURL, let u = URL(string: s) { return u }
        guard link.isOwner else { throw SocialError.badLink }
        let url = try await withBusy("Making invite link…") { try await shares.groupShareURL(zone: link.zone, name: link.nameCache) }
        store.setGroupShareURL(groupID, url)
        guard let u = URL(string: url) else { throw SocialError.badLink }
        return u
    }

    func joinGroup(_ offer: GroupJoinOffer) async {
        do {
            try requireCloud()
            try await withBusy("Joining \(offer.name)…") {
                let accepted: ShareService.Accepted
                if let m = offer.metadata {
                    accepted = try await shares.accept(metadata: m)
                } else if let u = offer.url {
                    accepted = try await shares.accept(url: u)
                } else {
                    throw SocialError.badLink
                }
                guard let gid = ZoneNames.groupID(fromZoneName: accepted.zone.zoneName) else { throw SocialError.badLink }
                if accepted.zone.isMine {
                    info("YOUR GROUP", "You made this one.")
                    return
                }
                await cloud.fetch(zone: accepted.zone)
                let name = store.cache.zones[accepted.zone]?.group?.name ?? accepted.title ?? offer.name
                store.registerJoinedGroup(zone: accepted.zone, groupID: gid, name: name, shareURL: offer.url?.absoluteString)
                tab = .groups
                show(Toast(style: .social, title: "JOINED \(name.uppercased())", body: "Group activity only. Full history stays between friends."))
            }
        } catch {
            self.error("Couldn't join", error)
        }
        groupOffers[offer.id] = nil
    }

    /// Owner only: remove someone from a group (their record, their poop copies, and their access).
    func removeMember(_ groupID: UUID, member: GroupMember) async {
        guard let link = store.my.groupLinks[groupID], link.isOwner else { return }
        guard store.removeMember(groupID, member: member.id) else { return }
        do {
            try await shares.removeFromGroup(zone: link.zone, uid: member.id)
            info("REMOVED", "@\(member.person.handle) is out of \(link.nameCache).")
        } catch {
            self.error("Removed from the list, but iCloud access may remain", error)
        }
    }

    func leaveGroup(_ groupID: UUID) {
        guard let link = store.my.groupLinks[groupID] else { return }
        store.removeGroupLocal(groupID)
        if link.isOwner { shares.deleteOwned(link.zone) } else { shares.leave(link.zone) }
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
    }

    // MARK: - Poop With Me

    /// Starts Poop With Me with friends (ad-hoc private space) — my own poop already counted.
    func startPWM(friends: [PersonRef]) async -> UUID? {
        do {
            try requireCloud()
            guard store.liveEvent != nil else { throw SocialError.noLiveSession }
            return try await withBusy("Inviting…") {
                let zone = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session(UUID()))
                let uids = friends.map(\.id)
                let url = try await shares.spaceShareURL(zone: zone, title: "Poop With Me", participants: uids)
                store.registerSpace(SpaceLink(zone: zone, kind: .pwm, isOwner: true, shareURL: url, participantIDs: uids, expiresAt: Date().addingTimeInterval(6 * 3600)))
                return store.createPWMSession(zone: zone, groupID: nil, invitees: friends)
            }
        } catch {
            self.error("Couldn't start Poop With Me", error)
            return nil
        }
    }

    /// Starts Poop With Me inside a group (members are reached through the group).
    func startPWM(group: GroupSummary, invitees: [PersonRef]) -> UUID? {
        guard store.liveEvent != nil else {
            info("TAP POOP NOW FIRST", "Poop With Me starts from a running timer.")
            return nil
        }
        return store.createPWMSession(zone: group.link.zone, groupID: group.link.id, invitees: invitees)
    }

    func inviteMore(_ view: LiveSessionView, people: [PersonRef]) async {
        do {
            if view.zone.isMine, store.my.spaceLinks[view.zone] != nil {
                _ = try await shares.spaceShareURL(zone: view.zone, title: "Poop With Me", participants: people.map(\.id))
            }
            store.inviteMore(zone: view.zone, sessionID: view.session.id, invitees: people)
        } catch {
            self.error("Couldn't invite", error)
        }
    }

    /// JOIN = I'm actually pooping now.
    /// `afterDismissal`: the caller is closing a sheet in the same tap (the +1 still happens instantly).
    func joinPWM(_ sessionID: UUID, afterDismissal: Bool = false) {
        guard let view = store.liveSession(sessionID) else {
            info("TOO LATE", "That session already ended.")
            return
        }
        store.joinPWM(zone: view.zone, sessionID: sessionID)
        openPWM = sessionID
        presentSession(afterDismissal: afterDismissal)
    }

    // MARK: - Parties

    func createParty(title: String, at date: Date, group: GroupSummary?, friends: [PersonRef]) async -> UUID? {
        do {
            try requireCloud()
            if let group {
                let invitees = group.members.map(\.person).filter { $0.id != store.userID }
                return store.createParty(zone: group.link.zone, groupID: group.link.id, title: title, at: date, invitees: invitees)
            }
            return try await withBusy("Scheduling…") {
                let zone = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session(UUID()))
                let uids = friends.map(\.id)
                let url = try await shares.spaceShareURL(zone: zone, title: title, participants: uids)
                store.registerSpace(SpaceLink(zone: zone, kind: .party, isOwner: true, shareURL: url, participantIDs: uids, expiresAt: date.addingTimeInterval(24 * 3600)))
                return store.createParty(zone: zone, groupID: nil, title: title, at: date, invitees: friends)
            }
        } catch {
            self.error("Couldn't schedule", error)
            return nil
        }
    }

    func joinParty(_ view: PartyView, afterDismissal: Bool = false) {
        store.joinParty(zone: view.zone, partyID: view.party.id)
        presentSession(afterDismissal: afterDismissal)
    }

    // MARK: - Notification taps

    func handleNotification(userInfo: [AnyHashable: Any], action: String) {
        let kind = userInfo[NotificationManager.Key.kind] as? String
        if action == NotificationCategory.actionDone {
            if let s = userInfo[NotificationManager.Key.event] as? String, let id = UUID(uuidString: s) { store.finish(id) } else { store.finish() }
            return
        }
        if let s = userInfo[NotificationManager.Key.party] as? String, let pid = UUID(uuidString: s) {
            if action == NotificationCategory.actionJoin {
                // JOIN = "I'm pooping now": +1 and the timer start immediately, before any network.
                if let p = store.party(pid) {
                    joinParty(p)
                } else {
                    let event = store.startTimed(partyID: pid)
                    presentSession()
                    Task {
                        await refresh()
                        if let p = store.party(pid) { store.attachToParty(zone: p.zone, partyID: pid, eventID: event.id) }
                    }
                }
                return
            }
            Task {
                await refresh()
                sheet = .party(pid)
            }
            return
        }
        if let s = userInfo[NotificationManager.Key.session] as? String, let sid = UUID(uuidString: s) {
            let share = userInfo[NotificationManager.Key.share] as? String
            if action == NotificationCategory.actionJoin {
                if store.liveSession(sid) != nil {
                    joinPWM(sid)
                } else {
                    // Count it and start the timer now; attach to the session once it has synced.
                    let event = store.startTimed(pwmSessionID: sid)
                    openPWM = sid
                    presentSession()
                    Task {
                        if let share { try? await joinSpace(url: share, kind: .pwm, expires: Date().addingTimeInterval(6 * 3600)) }
                        await refresh()
                        if let view = store.liveSession(sid) {
                            store.attachToPWM(zone: view.zone, sessionID: sid, eventID: event.id)
                        } else {
                            info("SESSION ENDED", "Everyone else finished. Your poop still counts.")
                        }
                    }
                }
                return
            }
            Task {
                if let share { try? await joinSpace(url: share, kind: .pwm, expires: Date().addingTimeInterval(6 * 3600)) }
                await refresh()
                sheet = .pwmInvite(sid)
            }
            return
        }
        switch kind {
        case "highlights-day": sheet = .highlights(.day, Date())
        case "highlights-week": sheet = .highlights(.week, Date().addingTimeInterval(-7 * 24 * 3600))
        case "highlights-month": sheet = .highlights(.month, Date().addingTimeInterval(-15 * 24 * 3600))
        case PingKind.friendRequest.rawValue: tab = .you
        case "highlights-group":
            if let raw = userInfo[NotificationManager.Key.group] as? String, let gid = UUID(uuidString: raw), let g = store.group(gid) {
                sheet = .groupHighlights(g.link.zone)
            } else {
                tab = .groups
            }
        default:
            if store.liveEvent != nil, kind == PingKind.pwmJoin.rawValue { showSession = true }
        }
        Task { await refresh() }
    }
}
