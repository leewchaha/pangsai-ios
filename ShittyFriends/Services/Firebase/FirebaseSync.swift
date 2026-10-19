import FirebaseFirestore
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "sync")

/// Firestore <-> Store. Local-first: every store mutation is applied at once and queued here; Firestore's
/// own offline persistence delivers the writes when the network is back. Everything I'm allowed to see
/// (my records, friends' histories, my groups and session spaces) arrives through live listeners, so
/// presence and Poop With Me need no polling.
@MainActor
final class FirebaseSync {
    enum Event {
        case friendRequest(IncomingFriendRequest)
        case friendshipConfirmed(UserID, PersonRef?)
        case friendshipEnded(UserID)
        case requestDeclined(UserID?)
        case groupApproved(UUID)
        case groupRequestEnded(UUID)
        case removedFromGroup(UUID)
    }

    let store: Store
    private(set) var availability: CloudAvailability = .unknown
    var onAvailabilityChange: ((CloudAvailability) -> Void)?
    var onRemoteChangesApplied: (() -> Void)?
    var onEvent: ((Event) -> Void)?

    private var uid: UserID?
    private var listeners: [String: ListenerRegistration] = [:]
    private var friendSet: Set<UserID> = []
    /// Groups whose create batch is still in flight: no listener yet, or the rules' `get()` on the
    /// missing group document would read as "gone" and wipe the brand-new group locally.
    private var creatingZones: Set<ZoneRef> = []
    private var queued: [QueuedChange]
    private let queueURL: URL
    private var refreshScheduled = false

    private var db: Firestore { Firestore.firestore() }

    init(store: Store, directory: URL) {
        self.store = store
        self.queueURL = directory.appendingPathComponent("sync-queue.json")
        self.queued = (try? JSONDecoder().decode([QueuedChange].self, from: Data(contentsOf: queueURL))) ?? []
    }

    // MARK: - Lifecycle

    /// Signed in: attach listeners and flush what was queued while signed out.
    func start(uid: UserID) {
        guard FirebaseConfig.isConfigured else {
            setAvailability(.notConfigured)
            return
        }
        if self.uid != uid { stop() }
        self.uid = uid
        setAvailability(.available)
        refreshListeners()
        sendAll()
    }

    /// Signed out (or switching accounts): drop every listener. The queue stays for the next sign-in.
    func stop() {
        for (_, l) in listeners { l.remove() }
        listeners = [:]
        friendSet = []
        uid = nil
        setAvailability(FirebaseConfig.isConfigured ? .noAccount : .notConfigured)
    }

    private func setAvailability(_ a: CloudAvailability) {
        guard availability != a else { return }
        availability = a
        onAvailabilityChange?(a)
    }

    // MARK: - Queueing writes

    func save(_ ref: RecordRef) { enqueue(QueuedChange(.save, zone: ref.zone, recordName: ref.recordName)) }
    func delete(_ ref: RecordRef) { enqueue(QueuedChange(.delete, zone: ref.zone, recordName: ref.recordName)) }

    /// A group space I own must exist (with me as owner + member and its invite code) before records land in it.
    func ensureZone(_ zone: ZoneRef) {
        guard zone.isMine, zone.isGroup else { return }
        enqueue(QueuedChange(.saveZone, zone: zone))
    }

    /// A space I own is finished: the server's housekeeping deletes it (and everything in it).
    func deleteZone(_ zone: ZoneRef) {
        guard zone.isMine, zone.isSpace else { return }
        queued.removeAll { $0.zone == zone && ($0.kind == .save || $0.kind == .delete) }
        enqueue(QueuedChange(.deleteZone, zone: zone))
    }

    private func enqueue(_ change: QueuedChange) {
        queued.removeAll { $0.supersededBy(change) }
        queued.append(change)
        persistQueue()
        scheduleSend()
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(queued) { try? data.write(to: queueURL, options: [.atomic]) }
    }

    /// Forget everything local about sync (used by "Delete all my data" and account switches).
    func resetLocalSyncState() {
        queued = []
        try? FileManager.default.removeItem(at: queueURL)
    }

    private var sendTask: Task<Void, Never>?

    private func scheduleSend() {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.sendAll()
        }
    }

    /// Hands every queued change to Firestore. Returns immediately: Firestore persists the writes and
    /// delivers them when online; failures (e.g. a permission denied for a record I may not write) are
    /// logged when the server answers.
    func sendAll() {
        guard let uid, FirebaseConfig.isConfigured, !queued.isEmpty else { return }
        let items = queued
        queued = []
        persistQueue()
        // A group being created in this run carries its info + owner row in the create batch itself.
        let creating = Set(items.filter { $0.kind == .saveZone }.map(\.zone))
        var batch = db.batch()
        var ops = 0
        func flush() {
            guard ops > 0 else { return }
            batch.commit { error in
                if let error { log.error("batch commit failed: \(error.localizedDescription, privacy: .public)") }
            }
            batch = db.batch()
            ops = 0
        }
        for item in items {
            switch item.kind {
            case .save:
                guard let name = item.recordName, let ref = RecordRef.parse(recordName: name, zone: item.zone),
                      let fields = FirestoreCoder.fields(for: ref, store: store) else { continue }
                if creating.contains(item.zone) {
                    if case .groupInfo = ref { continue }
                    if case .member(_, let m) = ref, m == uid { continue }
                }
                let doc = db.document(FirestorePaths.document(for: ref, me: uid))
                batch.setData(fields, forDocument: doc, merge: FirestoreCoder.mergesFields(ref))
                ops += 1
                if case .invite(let token) = ref, let inv = store.my.invites[token] {
                    batch.setData(["uid": uid, "createdAt": Timestamp(date: inv.createdAt), "expiresAt": Timestamp(date: inv.expiresAt)],
                                  forDocument: db.document(FirestorePaths.publicInvite(token)))
                    ops += 1
                }
            case .delete:
                guard let name = item.recordName, let ref = RecordRef.parse(recordName: name, zone: item.zone) else { continue }
                batch.deleteDocument(db.document(FirestorePaths.document(for: ref, me: uid)))
                ops += 1
                if case .invite(let token) = ref {
                    batch.deleteDocument(db.document(FirestorePaths.publicInvite(token)))
                    ops += 1
                }
            case .saveZone:
                flush()
                Task { await self.createGroupSpaceIfNeeded(item.zone, me: uid) }
            case .deleteZone:
                if let sid = item.zone.spaceID {
                    batch.updateData(["expiresAt": Timestamp(date: Date())], forDocument: db.document("spaces/\(sid.uuidString)"))
                    ops += 1
                }
            }
            if ops >= 450 { flush() }
        }
        flush()
    }

    /// Creates `groups/{gid}` with its structural fields (owner, members, bans, invite code), the owner's
    /// member row and the public invite-code document. Never touches an existing group document.
    private func createGroupSpaceIfNeeded(_ zone: ZoneRef, me: UserID) async {
        guard let gid = zone.groupID, let info = store.cache.zones[zone]?.group,
              let member = store.cache.zones[zone]?.members[me] else { return }
        creatingZones.insert(zone)
        let groupDoc = db.document("groups/\(gid.uuidString)")
        do {
            let existing = try await groupDoc.getDocument(source: .server)
            if existing.exists { creationFinished(zone); return }
        } catch {
            // Offline: fall through and let the queued create resolve when online (it fails harmlessly
            // if the group already exists, since the rules reject a second create).
        }
        guard var fields = try? FirestoreCoder.encoder.encode(info), let memberFields = try? FirestoreCoder.encoder.encode(member) else { creationFinished(zone); return }
        fields["ownerID"] = me
        fields["memberIDs"] = [me]
        fields["bannedIDs"] = [String]()
        let batch = db.batch()
        batch.setData(fields, forDocument: groupDoc)
        batch.setData(memberFields, forDocument: groupDoc.collection("members").document(me))
        batch.setData(["gid": gid.uuidString, "ownerID": me, "name": info.name, "object": info.object.rawValue, "color": info.color.rawValue, "createdAt": Timestamp(date: info.createdAt)],
                      forDocument: db.document(FirestorePaths.groupInvite(info.inviteCode)))
        batch.commit { error in
            if let error { log.error("group create failed: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor [weak self] in self?.creationFinished(zone) }
        }
    }

    private func creationFinished(_ zone: ZoneRef) {
        creatingZones.remove(zone)
        refreshListeners()
    }

    /// Sets `announce` on a poop so the server fans out "is pooping" / "just pooped" (after the Undo window).
    func announce(eventID: UUID) {
        guard let uid, FirebaseConfig.isConfigured, store.my.events[eventID] != nil else { return }
        db.document(FirestorePaths.document(for: .event(eventID), me: uid)).setData(["announce": true], merge: true) { error in
            if let error { log.error("announce failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Listeners

    /// Attaches listeners for everything the store currently refers to and drops the rest. Cheap to
    /// call often (debounced); the store asks for it whenever links change.
    func refreshListeners() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.refreshScheduled = false
            self.attachListeners()
        }
    }

    private func attachListeners() {
        guard let me = uid, FirebaseConfig.isConfigured else { return }
        var wanted: [String: () -> ListenerRegistration] = [:]
        let meZone = ZoneRef.me

        wanted["me"] = { self.listenDocument("users/\(me)", kind: .users, zone: meZone) }
        for kind in [FirestoreCoder.Kind.events, .achievements, .cosmetics] {
            wanted["me/\(kind.rawValue)"] = { self.listenCollection("users/\(me)/\(kind.rawValue)", kind: kind, zone: meZone) }
        }
        wanted["private/settings"] = { self.listenDocument("users/\(me)/private/settings", kind: .private, zone: .privateZone) }
        for kind in [FirestoreCoder.Kind.friendLinks, .groupLinks, .spaceLinks, .invites] {
            wanted["private/\(kind.rawValue)"] = { self.listenCollection("users/\(me)/\(kind.rawValue)", kind: kind, zone: .privateZone) }
        }
        wanted["friendships"] = { self.listenFriendships(me) }
        wanted["friendRequests/in"] = { self.listenIncomingRequests(me) }
        wanted["friendRequests/out"] = { self.listenOutgoingRequests(me) }
        wanted["spaces/invited"] = { self.listenInvitedSpaces(me) }

        // Friends' histories: everyone with an active link, plus friendships the server told us about.
        var friends = friendSet
        for link in store.my.friendLinks.values where link.status == .active {
            if let f = link.userID { friends.insert(f) }
        }
        for f in friends where f != me && !store.isBlocked(f) {
            let zone = ZoneRef(ownerName: f, zoneName: ZoneNames.me)
            wanted["friend/\(f)"] = { self.listenDocument("users/\(f)", kind: .users, zone: zone, onDenied: { [weak self] in self?.friendshipGone(f) }) }
            for kind in [FirestoreCoder.Kind.events, .achievements, .cosmetics] {
                wanted["friend/\(f)/\(kind.rawValue)"] = { self.listenCollection("users/\(f)/\(kind.rawValue)", kind: kind, zone: zone, onDenied: { [weak self] in self?.friendshipGone(f) }) }
            }
        }

        // Groups: members get everything; a pending requester only follows the group document and their own request.
        for link in store.my.groupLinks.values where !creatingZones.contains(link.zone) {
            let zone = link.zone
            guard let gid = zone.groupID else { continue }
            let root = "groups/\(gid.uuidString)"
            let denied: () -> Void = { [weak self] in self?.groupGone(gid, zone: zone) }
            wanted["zone/\(gid)"] = { self.listenDocument(root, kind: .groups, zone: zone, onDenied: link.status == .active ? denied : nil, onDeleted: denied) }
            if link.status == .requested {
                wanted["zone/\(gid)/myRequest"] = { self.listenMyJoinRequest(gid: gid, root: root, me: me) }
                continue
            }
            for kind in [FirestoreCoder.Kind.members, .events, .sessions, .participants, .reactions, .parties, .rsvps] {
                wanted["zone/\(gid)/\(kind.rawValue)"] = { self.listenCollection("\(root)/\(kind.rawValue)", kind: kind, zone: zone, onDenied: denied) }
            }
            if link.isOwner {
                wanted["zone/\(gid)/requests"] = { self.listenCollection("\(root)/requests", kind: .requests, zone: zone) }
            }
        }

        // Ad-hoc spaces (Poop With Me / parties between friends).
        for space in store.my.spaceLinks.values {
            let zone = space.zone
            guard let sid = zone.spaceID else { continue }
            let root = "spaces/\(sid.uuidString)"
            let denied: () -> Void = { [weak self] in self?.store.apply([.zoneDeleted(zone)]) }
            for kind in [FirestoreCoder.Kind.sessions, .participants, .reactions, .parties, .rsvps] {
                wanted["space/\(sid)/\(kind.rawValue)"] = { self.listenCollection("\(root)/\(kind.rawValue)", kind: kind, zone: zone, onDenied: denied) }
            }
        }

        for (key, l) in listeners where wanted[key] == nil {
            l.remove()
            listeners[key] = nil
        }
        for (key, make) in wanted where listeners[key] == nil {
            listeners[key] = make()
        }
    }

    private func listenDocument(_ path: String, kind: FirestoreCoder.Kind, zone: ZoneRef, onDenied: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) -> ListenerRegistration {
        db.document(path).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    if Self.isPermissionDenied(error) { onDenied?() } else { log.error("listen \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                    return
                }
                guard let snap else { return }
                if !snap.exists {
                    onDeleted?()
                    return
                }
                guard let record = FirestoreCoder.decode(kind: kind, documentID: snap.documentID, data: snap.data() ?? [:], inZone: zone) else { return }
                self.store.apply([.upsert(record, zone: zone)])
                self.onRemoteChangesApplied?()
            }
        }
    }

    private func listenCollection(_ path: String, kind: FirestoreCoder.Kind, zone: ZoneRef, onDenied: (() -> Void)? = nil) -> ListenerRegistration {
        db.collection(path).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    if Self.isPermissionDenied(error) { onDenied?() } else { log.error("listen \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                    return
                }
                guard let snap else { return }
                self.apply(snap, kind: kind, zone: zone)
            }
        }
    }

    private func apply(_ snap: QuerySnapshot, kind: FirestoreCoder.Kind, zone: ZoneRef) {
        var changes: [RemoteChange] = []
        for change in snap.documentChanges {
            let doc = change.document
            switch change.type {
            case .added, .modified:
                if let record = FirestoreCoder.decode(kind: kind, documentID: doc.documentID, data: doc.data(), inZone: zone) {
                    changes.append(.upsert(record, zone: zone))
                }
            case .removed:
                if let ref = FirestoreCoder.ref(kind: kind, documentID: doc.documentID, inZone: zone) {
                    changes.append(.delete(ref, zone: zone))
                }
            }
        }
        guard !changes.isEmpty else { return }
        store.apply(changes)
        onRemoteChangesApplied?()
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        (error as NSError).code == FirestoreErrorCode.permissionDenied.rawValue
    }

    // MARK: Friends

    private func listenFriendships(_ me: UserID) -> ListenerRegistration {
        db.collection("friendships").whereField("members", arrayContains: me).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self, let snap else { return }
                var changed = false
                for change in snap.documentChanges {
                    let members = (change.document.data()["members"] as? [String]) ?? []
                    guard let other = members.first(where: { $0 != me }) else { continue }
                    switch change.type {
                    case .added, .modified:
                        guard !self.friendSet.contains(other) else { continue }
                        self.friendSet.insert(other)
                        changed = true
                        // The first snapshot after start replays every existing friendship: only a new one is news.
                        let wasActive = self.store.friendLink(for: other)?.status == .active
                        let person = await self.fetchPerson(other)
                        self.store.friendshipConfirmed(with: other, person: person)
                        if !wasActive { self.onEvent?(.friendshipConfirmed(other, person)) }
                    case .removed:
                        self.friendSet.remove(other)
                        changed = true
                        self.store.friendshipEnded(with: other)
                        self.onEvent?(.friendshipEnded(other))
                    }
                }
                if changed { self.refreshListeners() }
            }
        }
    }

    private func friendshipGone(_ uid: UserID) {
        friendSet.remove(uid)
        store.friendshipEnded(with: uid)
        onEvent?(.friendshipEnded(uid))
        refreshListeners()
    }

    private func listenIncomingRequests(_ me: UserID) -> ListenerRegistration {
        db.collection("friendRequests").whereField("to", isEqualTo: me).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self, let snap else { return }
                for change in snap.documentChanges {
                    let d = change.document.data()
                    switch change.type {
                    case .added, .modified:
                        guard let token = d["inviteToken"] as? String, let person = FirestoreCoder.person(d["fromPerson"] as? [String: Any]) else { continue }
                        let at = (d["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let req = IncomingFriendRequest(id: change.document.documentID, inviteToken: token, person: person, receivedAt: at)
                        let isNew = self.store.my.requests[req.id] == nil
                        if self.store.receiveFriendRequest(req), isNew { self.onEvent?(.friendRequest(req)) }
                    case .removed:
                        self.store.dismissRequest(change.document.documentID)
                    }
                }
            }
        }
    }

    private func listenOutgoingRequests(_ me: UserID) -> ListenerRegistration {
        db.collection("friendRequests").whereField("from", isEqualTo: me).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self, let snap else { return }
                for change in snap.documentChanges where change.type == .removed {
                    let id = change.document.documentID
                    guard let link = self.store.my.friendLinks.values.first(where: { $0.requestID == id && $0.status == .requested }) else { continue }
                    // Declined (an accept arrives as a friendship first and clears the request itself).
                    let uid = link.userID
                    if uid.map({ self.friendSet.contains($0) }) ?? false { continue }
                    if let uid, (try? await self.db.document(FirestorePaths.friendship(me, uid)).getDocument(source: .server))?.exists == true {
                        continue // accepted: the friendships listener delivers it
                    }
                    self.store.cancelPendingLink(link.id)
                    self.onEvent?(.requestDeclined(uid))
                }
            }
        }
    }

    func fetchPerson(_ uid: UserID) async -> PersonRef? {
        guard FirebaseConfig.isConfigured else { return nil }
        guard let snap = try? await db.document("users/\(uid)").getDocument(), let data = snap.data(),
              let profile = try? FirestoreCoder.decoder.decode(UserProfile.self, from: data) else { return nil }
        return PersonRef(id: uid, profile: profile)
    }

    // MARK: Groups

    private func listenMyJoinRequest(gid: UUID, root: String, me: UserID) -> ListenerRegistration {
        db.document("\(root)/requests/\(me)").addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    if !Self.isPermissionDenied(error) { log.error("request listen: \(error.localizedDescription, privacy: .public)") }
                    return
                }
                guard let snap, !snap.exists else { return }
                // Request gone: approved (my member row exists) or declined. Check the member row.
                let member = try? await self.db.document("\(root)/members/\(me)").getDocument()
                if let member, member.exists, let data = member.data(), let m = try? FirestoreCoder.decoder.decode(GroupMember.self, from: data) {
                    let zone = self.store.my.groupLinks[gid]?.zone ?? ZoneRef.group(gid, ownerID: nil, me: me)
                    self.store.apply([.upsert(.member(m), zone: zone)])
                    self.onEvent?(.groupApproved(gid))
                    self.refreshListeners()
                } else if self.store.my.groupLinks[gid]?.status == .requested {
                    self.store.groupRequestEnded(gid)
                    self.onEvent?(.groupRequestEnded(gid))
                    self.refreshListeners()
                }
            }
        }
    }

    private func groupGone(_ gid: UUID, zone: ZoneRef) {
        guard store.my.groupLinks[gid] != nil else { return }
        store.apply([.zoneDeleted(zone)])
        onEvent?(.removedFromGroup(gid))
        refreshListeners()
    }

    // MARK: Spaces

    private func listenInvitedSpaces(_ me: UserID) -> ListenerRegistration {
        db.collection("spaces").whereField("memberIDs", arrayContains: me).addSnapshotListener { [weak self] snap, error in
            Task { @MainActor [weak self] in
                guard let self, let snap else { return }
                var changed = false
                for change in snap.documentChanges {
                    guard let sid = UUID(uuidString: change.document.documentID) else { continue }
                    let d = change.document.data()
                    let ownerID = d["ownerID"] as? String
                    let zone = ZoneRef.space(sid, ownerID: ownerID, me: me)
                    switch change.type {
                    case .added, .modified:
                        guard self.store.my.spaceLinks[zone] == nil else { continue }
                        let kind = SpaceKind(rawValue: (d["kind"] as? String) ?? "pwm") ?? .pwm
                        let expires = (d["expiresAt"] as? Timestamp)?.dateValue() ?? Date().addingTimeInterval(6 * 3600)
                        guard expires > Date() else { continue }
                        self.store.registerSpace(SpaceLink(zone: zone, kind: kind, isOwner: ownerID == me, title: (d["title"] as? String) ?? "", participantIDs: (d["memberIDs"] as? [String]) ?? [], createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date(), expiresAt: expires))
                        changed = true
                    case .removed:
                        guard let link = self.store.my.spaceLinks[zone], !link.isOwner else { continue }
                        self.store.removeSpace(zone)
                        changed = true
                    }
                }
                if changed { self.refreshListeners() }
            }
        }
    }

    // MARK: - One-shot fetches (after a notification tap, before listeners have caught up)

    /// Reads a group / space's live records from the server right now and applies them.
    func fetchZone(_ zone: ZoneRef) async {
        guard FirebaseConfig.isConfigured, uid != nil else { return }
        let root: String
        let kinds: [FirestoreCoder.Kind]
        if let gid = zone.groupID {
            root = "groups/\(gid.uuidString)"
            kinds = [.members, .events, .sessions, .participants, .reactions, .parties, .rsvps]
        } else if let sid = zone.spaceID {
            root = "spaces/\(sid.uuidString)"
            kinds = [.sessions, .participants, .reactions, .parties, .rsvps]
        } else {
            return
        }
        for kind in kinds {
            guard let snap = try? await db.collection("\(root)/\(kind.rawValue)").getDocuments(source: .server) else { continue }
            var changes: [RemoteChange] = []
            for doc in snap.documents {
                if let record = FirestoreCoder.decode(kind: kind, documentID: doc.documentID, data: doc.data(), inZone: zone) {
                    changes.append(.upsert(record, zone: zone))
                }
            }
            if !changes.isEmpty { store.apply(changes) }
        }
        onRemoteChangesApplied?()
    }

    /// A push named a space I was invited to: register it (if the server agrees I'm a member) and read it.
    func fetchSpace(_ sid: UUID) async -> ZoneRef? {
        guard FirebaseConfig.isConfigured, let me = uid else { return nil }
        guard let snap = try? await db.document("spaces/\(sid.uuidString)").getDocument(source: .server), let d = snap.data() else { return nil }
        let ownerID = d["ownerID"] as? String
        let zone = ZoneRef.space(sid, ownerID: ownerID, me: me)
        if store.my.spaceLinks[zone] == nil {
            let kind = SpaceKind(rawValue: (d["kind"] as? String) ?? "pwm") ?? .pwm
            let expires = (d["expiresAt"] as? Timestamp)?.dateValue() ?? Date().addingTimeInterval(6 * 3600)
            store.registerSpace(SpaceLink(zone: zone, kind: kind, isOwner: ownerID == me, title: (d["title"] as? String) ?? "", participantIDs: (d["memberIDs"] as? [String]) ?? [], expiresAt: expires))
            refreshListeners()
        }
        await fetchZone(zone)
        return zone
    }

    /// Finds the zone a session / party lives in from a push's ids.
    func zone(groupID: String?, spaceID: String?) -> ZoneRef? {
        guard let me = uid else { return nil }
        if let g = groupID, let gid = UUID(uuidString: g), let link = store.my.groupLinks[gid] { return link.zone }
        if let s = spaceID, let sid = UUID(uuidString: s) {
            if let link = store.my.spaceLinks.values.first(where: { $0.zone.spaceID == sid }) { return link.zone }
            return ZoneRef.space(sid, ownerID: nil, me: me)
        }
        return nil
    }
}

/// A change waiting to be handed to Firestore. Stored by zone + record name so it survives relaunch and
/// a signed-out stretch.
private struct QueuedChange: Codable, Hashable {
    enum Kind: String, Codable { case save, delete, saveZone, deleteZone }
    var kind: Kind
    var zone: ZoneRef
    var recordName: String?

    init(_ kind: Kind, zone: ZoneRef, recordName: String? = nil) {
        self.kind = kind
        self.zone = zone
        self.recordName = recordName
    }

    /// Whether `later` makes this queued change pointless (same record, or same zone for zone ops).
    func supersededBy(_ later: QueuedChange) -> Bool {
        guard zone == later.zone else { return false }
        switch (kind, later.kind) {
        case (.save, .save), (.save, .delete), (.delete, .save), (.delete, .delete):
            return recordName == later.recordName
        case (.saveZone, .saveZone), (.saveZone, .deleteZone), (.deleteZone, .saveZone), (.deleteZone, .deleteZone):
            return true
        case (.save, .deleteZone), (.delete, .deleteZone):
            return true
        default:
            return false
        }
    }
}
