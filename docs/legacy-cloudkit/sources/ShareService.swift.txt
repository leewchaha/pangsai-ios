import CloudKit
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "share")

/// All CloudKit sharing:
/// - My "Me" zone (full poop history) is a *private* zone-wide share. Friends are added one by one as
///   read-only participants by their user record ID, so unfriending revokes access immediately.
/// - Group zones are zone-wide shares with a public read-write link (the group invite).
/// - Ad-hoc session zones (Poop With Me / Parties between friends) are private read-write shares.
@MainActor
final class ShareService {
    enum ShareError: LocalizedError {
        case noURL
        case notSignedIn
        case participantLookupFailed
        case alreadyHandled

        var errorDescription: String? {
            switch self {
            case .noURL: return "iCloud didn't return a share link. Try again."
            case .notSignedIn: return "Sign in to iCloud to add friends."
            case .participantLookupFailed: return "Couldn't find that person on iCloud. Ask them to open ShittyFriends once while signed in."
            case .alreadyHandled: return "Already done."
            }
        }
    }

    var container: CKContainer { CloudConfig.container }
    let cloud: CloudSync
    let store: Store
    private var meShare: CKShare?

    init(cloud: CloudSync, store: Store) {
        self.cloud = cloud
        self.store = store
    }

    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    private func shareID(for zone: ZoneRef) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID)
    }

    // MARK: - Generic helpers

    /// Fetches the zone-wide share of a zone I own, or nil if there is none yet.
    private func fetchShare(_ zone: ZoneRef) async throws -> CKShare? {
        do {
            let record = try await privateDB.record(for: shareID(for: zone))
            return record as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Saves a share and returns the server copy (which carries the URL).
    private func save(_ share: CKShare) async throws -> CKShare {
        let result = try await privateDB.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys, atomically: true)
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else { throw ShareError.noURL }
        return saved
    }

    /// Fetches the participant object for a user, by iCloud user record name.
    private func participant(for uid: UserID, permission: CKShare.ParticipantPermission) async throws -> CKShare.Participant {
        do {
            let p = try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: uid))
            p.permission = permission
            return p
        } catch {
            log.error("participant lookup failed: \(error.localizedDescription, privacy: .public)")
            throw ShareError.participantLookupFailed
        }
    }

    private func hasParticipant(_ share: CKShare, uid: UserID) -> CKShare.Participant? {
        share.participants.first { $0.userIdentity.userRecordID?.recordName == uid && $0.role != .owner }
    }

    /// Retries once on a change-tag conflict by re-fetching the share and re-applying `mutate`.
    private func mutateShare(_ zone: ZoneRef, create: () -> CKShare, mutate: (CKShare) async throws -> Bool) async throws -> CKShare {
        for attempt in 0..<2 {
            let share: CKShare
            if let existing = try await fetchShare(zone) {
                share = existing
            } else {
                try await cloud.createZoneNow(zone)
                share = create()
            }
            let changed = try await mutate(share)
            if !changed, share.url != nil { return share }
            do {
                return try await save(share)
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                log.info("share changed on server, retrying")
                continue
            } catch let error as CKError where error.code == .partialFailure && attempt == 0 {
                log.info("share partial failure, retrying: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        throw ShareError.noURL
    }

    // MARK: - My history ("Me" zone)

    /// DEBUG-only bootstrap for Apple's system `cloudkit.share` record type. CloudKit creates that
    /// type only after a real share is saved in the Development environment; it must then be deployed
    /// once to Production before TestFlight/App Store builds can originate shares.
    func bootstrapDevelopmentSharingSchema() async {
        #if DEBUG
        do {
            _ = try await mutateShare(.me, create: makeMeShare) { _ in false }
            log.info("development sharing schema bootstrap completed")
        } catch {
            // A Debug build can still be pointed at Production; never surface this maintenance attempt.
            log.debug("development sharing schema bootstrap skipped/failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func makeMeShare() -> CKShare {
        let share = CKShare(recordZoneID: ZoneRef.me.zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "@\(store.profile.handle)'s poop history" as CKRecordValue
        return share
    }

    /// Adds a friend to my history share (read-only). Returns the share URL to send them.
    func shareMyHistory(with uid: UserID) async throws -> String {
        let share = try await mutateShare(.me, create: makeMeShare) { share in
            if self.hasParticipant(share, uid: uid) != nil { return false }
            share.addParticipant(try await self.participant(for: uid, permission: .readOnly))
            return true
        }
        meShare = share
        guard let url = share.url?.absoluteString else { throw ShareError.noURL }
        return url
    }

    /// Removes a former friend from my history share. Their access ends immediately.
    func unshareMyHistory(from uid: UserID) async {
        do {
            guard let share = try await fetchShare(.me), let p = hasParticipant(share, uid: uid) else { return }
            share.removeParticipant(p)
            meShare = try await save(share)
        } catch {
            log.error("unshare failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Self-healing revocation: removes anyone from my history share who is no longer a friend
    /// (e.g. an unfriend that failed offline, or was done on another device). `allowed` = user IDs
    /// with any friend link (active or mid-handshake).
    func reconcileHistoryShare(allowed: Set<UserID>) async {
        do {
            guard let share = try await fetchShare(.me) else { return }
            let stale = share.participants.filter { p in
                guard p.role != .owner, let uid = p.userIdentity.userRecordID?.recordName else { return false }
                return !allowed.contains(uid)
            }
            guard !stale.isEmpty else { return }
            for p in stale { share.removeParticipant(p) }
            meShare = try await save(share)
            log.info("revoked history access for \(stale.count) former friend(s)")
        } catch {
            log.error("history share reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Groups

    /// Owner only: takes a member out of a group zone's share. (Anyone holding the group link can
    /// still ask to rejoin; the owner can remove them again.)
    func removeFromGroup(zone: ZoneRef, uid: UserID) async throws {
        guard zone.isMine, let share = try await fetchShare(zone), let p = hasParticipant(share, uid: uid) else { return }
        share.removeParticipant(p)
        _ = try await save(share)
    }

    /// Creates (or returns) the public read-write link for a group zone I own.
    func groupShareURL(zone: ZoneRef, name: String) async throws -> String {
        let share = try await mutateShare(zone, create: {
            let s = CKShare(recordZoneID: zone.zoneID)
            s.publicPermission = .readWrite
            s[CKShare.SystemFieldKey.title] = name as CKRecordValue
            return s
        }, mutate: { share in
            var changed = false
            if share.publicPermission != .readWrite { share.publicPermission = .readWrite; changed = true }
            if (share[CKShare.SystemFieldKey.title] as? String) != name {
                share[CKShare.SystemFieldKey.title] = name as CKRecordValue
                changed = true
            }
            return changed
        })
        guard let url = share.url?.absoluteString else { throw ShareError.noURL }
        return url
    }

    // MARK: - Ad-hoc session spaces

    /// Creates a private read-write share for a session zone I own and adds the given friends.
    func spaceShareURL(zone: ZoneRef, title: String, participants uids: [UserID]) async throws -> String {
        let share = try await mutateShare(zone, create: {
            let s = CKShare(recordZoneID: zone.zoneID)
            s.publicPermission = .none
            s[CKShare.SystemFieldKey.title] = title as CKRecordValue
            return s
        }, mutate: { share in
            var changed = false
            for uid in uids where self.hasParticipant(share, uid: uid) == nil {
                if let p = try? await self.participant(for: uid, permission: .readWrite) {
                    share.addParticipant(p)
                    changed = true
                }
            }
            return changed
        })
        guard let url = share.url?.absoluteString else { throw ShareError.noURL }
        return url
    }

    // MARK: - Friend invite cards

    private var invitesZone: ZoneRef { ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.invites) }

    private func cardIDs(_ token: String) -> (card: CKRecord.ID, share: CKRecord.ID) {
        (CKRecord.ID(recordName: "IC-" + token, zoneID: invitesZone.zoneID),
         CKRecord.ID(recordName: "ICS-" + token, zoneID: invitesZone.zoneID))
    }

    /// Creates (or returns) the https link for a friend invite. The link points at a tiny "invite card"
    /// record shared read-only with anyone who has the link. The card holds only the invite payload
    /// (handle, color, avatar, invite token + secret) — never history.
    func inviteCardURL(token: String, payload: FriendInvitePayload) async throws -> String {
        let ids = cardIDs(token)
        if let existing = try? await privateDB.record(for: ids.share) as? CKShare, let url = existing.url {
            return url.absoluteString
        }
        try await cloud.createZoneNow(invitesZone)
        let card = CKRecord(recordType: RecordTypes.inviteCard, recordID: ids.card)
        card[RecordTypes.inviteCardPayloadKey] = payload.encoded as CKRecordValue
        let share = CKShare(rootRecord: card, shareID: ids.share)
        share.publicPermission = .readOnly
        share[CKShare.SystemFieldKey.title] = "Become shitty friends with @\(payload.h) 💩" as CKRecordValue
        let result = try await privateDB.modifyRecords(saving: [card, share], deleting: [], savePolicy: .allKeys, atomically: true)
        guard let saved = try result.saveResults[ids.share]?.get() as? CKShare, let url = saved.url else { throw ShareError.noURL }
        return url.absoluteString
    }

    func deleteInviteCard(token: String) async {
        let ids = cardIDs(token)
        do {
            _ = try await privateDB.modifyRecords(saving: [], deleting: [ids.share, ids.card], savePolicy: .allKeys, atomically: false)
        } catch {
            log.error("invite card delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches share metadata including the root record (for record-hierarchy shares).
    func metadataWithRoot(_ url: URL) async throws -> CKShare.Metadata {
        final class Box: @unchecked Sendable { var result: Result<CKShare.Metadata, Error>? }
        let box = Box()
        let op = CKFetchShareMetadataOperation(shareURLs: [url])
        op.shouldFetchRootRecord = true
        op.rootRecordDesiredKeys = [RecordTypes.inviteCardPayloadKey]
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKShare.Metadata, Error>) in
            op.perShareMetadataResultBlock = { @Sendable _, result in box.result = result }
            op.fetchShareMetadataResultBlock = { @Sendable opResult in
                switch opResult {
                case .failure(let error):
                    cont.resume(throwing: error)
                case .success:
                    if let r = box.result { cont.resume(with: r) } else { cont.resume(throwing: ShareError.noURL) }
                }
            }
            container.add(op)
        }
    }

    enum InviteCardResult {
        case invite(FriendInvitePayload)
        case mine
        case notAnInvite
    }

    /// Reads the friend invite behind a share link without joining anything.
    func readInviteCard(_ metadata: CKShare.Metadata) async throws -> InviteCardResult {
        let zoneID = metadata.share.recordID.zoneID
        guard zoneID.zoneName == ZoneNames.invites else { return .notAnInvite }
        if metadata.participantRole == .owner { return .mine }
        func decode(_ record: CKRecord?) -> FriendInvitePayload? {
            (record?[RecordTypes.inviteCardPayloadKey] as? String).flatMap(FriendInvitePayload.decode)
        }
        if let p = decode(metadata.rootRecord) { return .invite(p) }
        if let url = metadata.share.url {
            let refetched = try? await metadataWithRoot(url)
            if let p = decode(refetched?.rootRecord) { return .invite(p) }
        }
        // Fallback: join the card share, read the card, leave again.
        guard let rootID = metadata.hierarchicalRootRecordID else { return .notAnInvite }
        if metadata.participantStatus != .accepted { _ = try await container.accept(metadata) }
        defer { cloud.leaveZone(ZoneRef(zoneID)) }
        let root = try await sharedDB.record(for: rootID)
        guard let p = decode(root) else { return .notAnInvite }
        return .invite(p)
    }

    // MARK: - Accepting

    struct Accepted {
        var zone: ZoneRef
        var ownerID: UserID
        var title: String?
    }

    /// Accepts a share link (friend history, group or session). Idempotent.
    @discardableResult
    func accept(url: URL) async throws -> Accepted {
        let metadata = try await container.shareMetadata(for: url)
        return try await accept(metadata: metadata)
    }

    @discardableResult
    func accept(metadata: CKShare.Metadata) async throws -> Accepted {
        let zoneID = metadata.share.recordID.zoneID
        let owner = metadata.ownerIdentity.userRecordID?.recordName ?? zoneID.ownerName
        if metadata.participantRole == .owner {
            // My own link (e.g. I tapped my group invite).
            return Accepted(zone: ZoneRef(ownerName: ZoneRef.currentUser, zoneName: zoneID.zoneName), ownerID: owner, title: metadata.share[CKShare.SystemFieldKey.title] as? String)
        }
        if metadata.participantStatus != .accepted {
            _ = try await container.accept(metadata)
        }
        await cloud.fetchShared()
        return Accepted(zone: ZoneRef(zoneID), ownerID: owner, title: metadata.share[CKShare.SystemFieldKey.title] as? String)
    }

    // MARK: - Leaving / deleting

    /// Leaves a zone someone else shared with me (friend history, group or session).
    func leave(_ zone: ZoneRef) {
        guard !zone.isMine else { return }
        cloud.leaveZone(zone)
    }

    /// Deletes a zone I own (and with it, everyone's access).
    func deleteOwned(_ zone: ZoneRef) {
        guard zone.isMine else { return }
        cloud.deleteZone(zone)
    }
}
