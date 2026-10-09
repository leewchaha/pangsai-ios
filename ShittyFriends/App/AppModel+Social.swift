import Foundation
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "social")

enum SocialActionError: LocalizedError {
    case needsSignIn
    case noLiveSession
    case nothingToJoin
    case badLink

    var errorDescription: String? {
        switch self {
        case .needsSignIn: return "Sign in (YOU → Settings) to do this. Logging works without it."
        case .noLiveSession: return "Start pooping first."
        case .nothingToJoin: return "That session is over."
        case .badLink: return "That link isn't a ShittyFriends invite."
        }
    }
}

extension AppModel {
    private func requireSignIn() throws {
        guard availability.isAvailable, store.userID != nil, store.userID != UserID.localMe else { throw SocialActionError.needsSignIn }
    }

    private func withBusy<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        busy = label
        defer { busy = nil }
        return try await body()
    }

    // MARK: - Friend invites (A side)

    /// QR/share payload for my current invite.
    func friendInviteURL() async throws -> URL {
        try requireSignIn()
        let payload = store.friendInvitePayload()
        sync.sendAll()
        return DeepLinkCodec.friendURL(payload)
    }

    func friendInviteText(_ url: URL) -> String {
        DeepLinkCodec.friendShareText(handle: store.profile.handle, url: url)
    }

    /// A taps ACCEPT on a request: the friendship record is created; both sides see it come back.
    func acceptFriendRequest(_ request: IncomingFriendRequest) async {
        do {
            try requireSignIn()
            try await withBusy("Becoming shitty friends…") {
                let link = try store.acceptFriendRequest(request.id)
                guard let uid = link.userID else { return }
                try await social.acceptFriendRequest(requestID: request.id, from: uid)
            }
        } catch Store.HandshakeError.alreadyFriends {
            info("ALREADY FRIENDS", "@\(request.person.handle) is already a shitty friend.")
        } catch Store.HandshakeError.blocked {
            info("BLOCKED", "Unblock @\(request.person.handle) in Settings first.")
        } catch {
            self.error("Couldn't accept", error)
        }
    }

    func declineFriendRequest(_ request: IncomingFriendRequest, block: Bool) {
        store.dismissRequest(request.id)
        if block { store.block(request.person.id) }
        Task { await social.deleteFriendRequest(request.id) }
    }

    // MARK: - Friend invites (B side)

    /// B confirmed "BECOME SHITTY FRIENDS?" on someone's invite.
    func sendFriendRequest(_ invite: FriendInvitePayload) {
        do {
            try requireSignIn()
            let link = try store.beginFriendRequest(invite)
            Task {
                do {
                    let other: UserID
                    if let u = invite.u { other = u } else { other = try await social.resolveInvite(token: invite.t) }
                    if other == store.userID {
                        store.cancelPendingLink(link.id)
                        info("THAT'S YOU", "You can't befriend yourself. Emotionally, maybe.")
                        return
                    }
                    if store.isBlocked(other) {
                        store.cancelPendingLink(link.id)
                        info("BLOCKED", "Unblock them in Settings first.")
                        return
                    }
                    let requestID = try await social.sendFriendRequest(to: other, inviteToken: invite.t)
                    store.markRequestSent(linkID: link.id, requestID: requestID, userID: other)
                    info("REQUEST SENT", "@\(invite.h) has to accept. Then your histories unlock.")
                } catch {
                    store.cancelPendingLink(link.id)
                    self.error("Couldn't send request", error)
                }
            }
        } catch Store.HandshakeError.ownInvite {
            info("THAT'S YOU", "You can't befriend yourself. Emotionally, maybe.")
        } catch Store.HandshakeError.alreadyFriends {
            info("ALREADY FRIENDS", "@\(invite.h) is already a shitty friend.")
        } catch Store.HandshakeError.blocked {
            info("BLOCKED", "Unblock @\(invite.h) in Settings first.")
        } catch {
            self.error("Couldn't send request", error)
        }
    }

    /// Cancel a request I sent, or a pending acceptance.
    func cancelPendingLink(_ link: FriendLink) {
        let requestID = link.requestID
        store.cancelPendingLink(link.id)
        if let requestID { Task { await social.deleteFriendRequest(requestID) } }
    }

    // MARK: - Removing friends

    /// Unfriend: the friendship record goes; both sides lose access at once.
    func removeFriend(_ link: FriendLink) async {
        let uid = link.userID
        store.removeFriendLocal(link.id)
        guard let uid else { return }
        await social.unfriend(uid)
    }

    func blockFriend(_ link: FriendLink) async {
        // `block` drops the link and their cached history and emits `.friendZoneGone` (-> unfriend).
        if let uid = link.userID { store.block(uid) }
        await removeFriend(link)
    }

    // MARK: - Links (URLs, QR codes, pasted text)

    func handle(url: URL) {
        if auth.handle(url: url) { return }
        guard let link = DeepLinkCodec.parse(url) else {
            info("UNKNOWN LINK", "That isn't a ShittyFriends link.")
            return
        }
        switch link {
        case .friendInvite(let p):
            sheet = .friendInvite(p)
        case .groupInvite(let p):
            offerGroupJoin(GroupJoinOffer(name: p.n, color: p.color, object: p.object, code: p.k))
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
            case .friendInvite(let p): sheet = .friendInvite(p)
            case .groupInvite(let p): offerGroupJoin(GroupJoinOffer(name: p.n, color: p.color, object: p.object, code: p.k))
            default: break
            }
        } else {
            info("NO LINK FOUND", "Copy the whole invite message and try again.")
        }
    }

    // MARK: - Groups

    private func offerGroupJoin(_ offer: GroupJoinOffer) {
        if let mine = store.my.groupLinks.values.first(where: { link in store.cache.zones[link.zone]?.group?.inviteCode == offer.code }) {
            info(mine.status == .active ? "ALREADY IN" : "ALREADY ASKED", mine.status == .active ? "You're already in \(mine.nameCache)." : "Waiting for the owner of \(mine.nameCache).")
            return
        }
        groupOffers[offer.id] = offer
        sheet = .groupJoin(offer.id)
    }

    func createGroup(name: String, object: GroupObject, color: IdentityColor) async -> GroupLink? {
        do {
            try requireSignIn()
            guard let link = store.createGroupLocal(name: name, object: object, color: color) else {
                info("PICK ANOTHER NAME", "Up to 28 characters, nothing offensive.")
                return nil
            }
            sync.sendAll()
            return link
        } catch {
            self.error("Couldn't create group", error)
            return nil
        }
    }

    func groupInviteURL(_ groupID: UUID) async throws -> URL {
        try requireSignIn()
        guard let g = store.group(groupID), let info = g.info, !info.inviteCode.isEmpty else { throw SocialActionError.badLink }
        return DeepLinkCodec.groupURL(GroupInvitePayload(name: info.name, object: info.object, color: info.color, code: info.inviteCode))
    }

    /// "ASK TO JOIN": the owner approves each join.
    func joinGroup(_ offer: GroupJoinOffer) async {
        do {
            try requireSignIn()
            try await withBusy("Asking to join \(offer.name)…") {
                let (outcome, preview) = try await social.requestJoin(code: offer.code)
                switch outcome {
                case .member:
                    // Already a member (e.g. reinstalled): the group streams back through sync.
                    if store.my.groupLinks[preview.gid] == nil {
                        store.registerGroupRequest(groupID: preview.gid, ownerID: preview.ownerID, name: preview.name, object: preview.object, color: preview.color)
                        store.groupApproved(preview.gid, joinedAt: Date())
                    }
                    tab = .groups
                    info("YOU'RE IN", "You're already a member of \(preview.name).")
                case .requested:
                    store.registerGroupRequest(groupID: preview.gid, ownerID: preview.ownerID, name: preview.name, object: preview.object, color: preview.color)
                    tab = .groups
                    show(Toast(style: .social, title: "ASKED TO JOIN \(preview.name.uppercased())", body: "The owner decides. You'll get a nudge when you're in."))
                }
            }
        } catch {
            self.error("Couldn't ask to join", error)
        }
        groupOffers[offer.id] = nil
    }

    /// Owner only: approves a join request (the server writes the member row; it streams back).
    func approveJoin(_ groupID: UUID, request: GroupJoinRequest) async {
        guard store.settleJoinRequest(groupID, member: request.id) != nil else { return }
        do {
            try await social.approveJoin(gid: groupID, uid: request.id)
            info("APPROVED", "@\(request.person.handle) is in.")
        } catch {
            self.error("Couldn't approve", error)
            await sync.fetchZone(store.my.groupLinks[groupID]?.zone ?? .me)
        }
    }

    func declineJoin(_ groupID: UUID, request: GroupJoinRequest) async {
        guard store.settleJoinRequest(groupID, member: request.id) != nil else { return }
        do {
            try await social.declineJoin(gid: groupID, uid: request.id)
        } catch {
            self.error("Couldn't decline", error)
        }
    }

    /// Owner only: remove someone from a group. They lose access now and can't rejoin with the link.
    func removeMember(_ groupID: UUID, member: GroupMember) async {
        guard let link = store.my.groupLinks[groupID], link.isOwner else { return }
        guard store.removeMember(groupID, member: member.id) else { return }
        do {
            try await social.kick(gid: groupID, uid: member.id)
            info("REMOVED", "@\(member.person.handle) is out of \(link.nameCache) and can't rejoin with the link.")
        } catch {
            self.error("Removed from the list, but the server didn't confirm", error)
        }
    }

    func leaveGroup(_ groupID: UUID) {
        guard let link = store.my.groupLinks[groupID] else { return }
        if link.status == .requested {
            // Withdrawing a join request the owner hasn't answered yet.
            store.groupRequestEnded(groupID)
            Task { try? await social.cancelJoinRequest(gid: groupID) }
            return
        }
        store.removeGroupLocal(groupID)
        Task {
            do {
                if link.isOwner { try await social.deleteGroup(gid: groupID) } else { try await social.leaveGroup(gid: groupID) }
            } catch {
                self.error(link.isOwner ? "Couldn't delete on the server" : "Couldn't leave on the server", error)
            }
        }
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
    }

    // MARK: - Poop With Me

    /// Starts Poop With Me with friends (ad-hoc space) — my own poop already counted.
    func startPWM(friends: [PersonRef]) async -> UUID? {
        do {
            try requireSignIn()
            guard store.liveEvent != nil, let me = store.userID else { throw SocialActionError.noLiveSession }
            return try await withBusy("Inviting…") {
                let id = UUID()
                let zone = ZoneRef.space(id, ownerID: me, me: me)
                let uids = friends.map(\.id)
                let expires = Date().addingTimeInterval(6 * 3600)
                try await social.createSpace(id: id, kind: .pwm, title: "Poop With Me", members: uids, expiresAt: expires)
                store.registerSpace(SpaceLink(zone: zone, kind: .pwm, isOwner: true, title: "Poop With Me", participantIDs: uids, expiresAt: expires))
                let sid = store.createPWMSession(zone: zone, groupID: nil, invitees: friends)
                sync.sendAll()
                return sid
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
        let sid = store.createPWMSession(zone: group.link.zone, groupID: group.link.id, invitees: invitees)
        sync.sendAll()
        return sid
    }

    func inviteMore(_ view: LiveSessionView, people: [PersonRef]) async {
        do {
            if let sid = view.zone.spaceID, store.my.spaceLinks[view.zone]?.isOwner == true {
                try await social.addSpaceMembers(id: sid, members: people.map(\.id))
            }
            store.inviteMore(zone: view.zone, sessionID: view.session.id, invitees: people)
            sync.sendAll()
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
        guard store.canJoinPWM(sessionID) else {
            // Already pooping in this session: never a second +1, just open it.
            openPWM = sessionID
            presentSession(afterDismissal: afterDismissal)
            return
        }
        store.joinPWM(zone: view.zone, sessionID: sessionID)
        sync.sendAll()
        openPWM = sessionID
        presentSession(afterDismissal: afterDismissal)
    }

    // MARK: - Parties

    func createParty(title: String, at date: Date, group: GroupSummary?, friends: [PersonRef]) async -> UUID? {
        do {
            try requireSignIn()
            if let group {
                let invitees = group.members.map(\.person).filter { $0.id != store.userID }
                let pid = store.createParty(zone: group.link.zone, groupID: group.link.id, title: title, at: date, invitees: invitees)
                sync.sendAll()
                return pid
            }
            guard let me = store.userID else { throw SocialActionError.needsSignIn }
            return try await withBusy("Scheduling…") {
                let id = UUID()
                let zone = ZoneRef.space(id, ownerID: me, me: me)
                let uids = friends.map(\.id)
                let expires = date.addingTimeInterval(24 * 3600)
                try await social.createSpace(id: id, kind: .party, title: title, members: uids, expiresAt: expires)
                store.registerSpace(SpaceLink(zone: zone, kind: .party, isOwner: true, title: title, participantIDs: uids, expiresAt: expires))
                let pid = store.createParty(zone: zone, groupID: nil, title: title, at: date, invitees: friends)
                sync.sendAll()
                return pid
            }
        } catch {
            self.error("Couldn't schedule", error)
            return nil
        }
    }

    func joinParty(_ view: PartyView, afterDismissal: Bool = false) {
        guard store.canJoinParty(view.party.id) else {
            partyNotJoinable(view)
            return
        }
        store.joinParty(zone: view.zone, partyID: view.party.id)
        sync.sendAll()
        presentSession(afterDismissal: afterDismissal)
    }

    private func partyNotJoinable(_ view: PartyView) {
        if store.myRSVP(view)?.joinedAt != nil {
            info("YOU'RE ALREADY IN", "Your poop for \(view.party.title) already counted.")
            if store.liveEvent != nil { presentSession() }
        } else if view.party.status == .cancelled {
            info("PARTY CANCELLED", "\(view.party.title) isn't happening.")
        } else if view.party.isOver(now: Date()) {
            info("PARTY'S OVER", "\(view.party.title) ended. POOP NOW still counts for you.")
        } else {
            info("NOT YET", "\(view.party.title) opens 10 minutes before it starts.")
            sheet = .party(view.party.id)
        }
    }

    /// Deletes (owner) session spaces that are past their expiry; guests just forget them.
    func cleanupSpaces() {
        for space in store.expiredSpaces() {
            if space.isOwner { sync.deleteZone(space.zone) }
            store.removeSpace(space.zone)
        }
    }

    // MARK: - Notification taps

    /// Makes sure the zone a push named is known and freshly read (ad-hoc spaces may not be linked yet).
    private func zoneFromPush(_ userInfo: [AnyHashable: Any]) async -> ZoneRef? {
        let groupID = userInfo[PushField.groupID] as? String
        let spaceID = userInfo[PushField.space] as? String
        if let s = spaceID, let sid = UUID(uuidString: s), store.my.spaceLinks.values.first(where: { $0.zone.spaceID == sid }) == nil {
            return await sync.fetchSpace(sid)
        }
        guard let zone = sync.zone(groupID: groupID, spaceID: spaceID) else { return nil }
        await sync.fetchZone(zone)
        return zone
    }

    func handleNotification(userInfo: [AnyHashable: Any], action: String) {
        let kind = userInfo[NotificationManager.Key.kind] as? String
        if action == NotificationCategory.actionDone {
            if let s = userInfo[NotificationManager.Key.event] as? String, let id = UUID(uuidString: s) { store.finish(id) } else { store.finish() }
            return
        }
        if let s = userInfo[NotificationManager.Key.party] as? String, let pid = UUID(uuidString: s) {
            if action == NotificationCategory.actionJoin {
                // JOIN = "I'm pooping now": +1 and the timer start immediately, before any network.
                // The party itself is checked first (stale alert, cancelled, already joined); an
                // unknown party gets the poop now and is attached only if it turns out to be live.
                if let p = store.party(pid) {
                    joinParty(p)
                } else {
                    let event = store.startTimed(partyID: pid)
                    presentSession()
                    Task {
                        _ = await zoneFromPush(userInfo)
                        if let p = store.party(pid) {
                            if store.canJoinParty(pid) {
                                store.attachToParty(zone: p.zone, partyID: pid, eventID: event.id)
                                sync.sendAll()
                            } else {
                                store.detachFromParty(eventID: event.id)
                                info("PARTY'S OVER", "\(p.party.title) had ended. Your poop still counts.")
                            }
                        } else {
                            store.detachFromParty(eventID: event.id)
                            info("PARTY NOT FOUND", "It was cancelled or never synced. Your poop still counts.")
                        }
                    }
                }
                return
            }
            Task {
                _ = await zoneFromPush(userInfo)
                sheet = .party(pid)
            }
            return
        }
        if let s = userInfo[NotificationManager.Key.session] as? String, let sid = UUID(uuidString: s) {
            if action == NotificationCategory.actionJoin {
                if store.liveSession(sid) != nil {
                    joinPWM(sid)
                } else if store.liveEvent?.pwmSessionID == sid {
                    // Already in it (a second JOIN on a stacked alert): just open the session.
                    openPWM = sid
                    presentSession()
                } else {
                    // Count it and start the timer now; attach to the session once it has synced.
                    let event = store.startTimed(pwmSessionID: sid)
                    openPWM = sid
                    presentSession()
                    Task {
                        _ = await zoneFromPush(userInfo)
                        if let view = store.liveSession(sid) {
                            store.attachToPWM(zone: view.zone, sessionID: sid, eventID: event.id)
                            sync.sendAll()
                        } else {
                            store.detachFromPWM(eventID: event.id)
                            info("SESSION ENDED", "Everyone else finished. Your poop still counts.")
                        }
                    }
                }
                return
            }
            Task {
                _ = await zoneFromPush(userInfo)
                sheet = .pwmInvite(sid)
            }
            return
        }
        switch kind {
        case "highlights-day": sheet = .highlights(.day, Date())
        case "highlights-week": sheet = .highlights(.week, Date().addingTimeInterval(-7 * 24 * 3600))
        case "highlights-month": sheet = .highlights(.month, Date().addingTimeInterval(-15 * 24 * 3600))
        case PingKind.friendRequest.rawValue, PingKind.friendComplete.rawValue: tab = .you
        case PingKind.groupJoinRequest.rawValue, PingKind.groupJoined.rawValue: tab = .groups
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
