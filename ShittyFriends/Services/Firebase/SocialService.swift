import FirebaseFirestore
import FirebaseFunctions
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "social")

/// Everything social that is more than "save my record": friend requests and friendships, group join
/// requests / approvals / kicks (Cloud Functions, so they stick), ad-hoc session spaces, blocks, and
/// server-side account deletion. All calls need the network; the store already applied the local part.
@MainActor
final class SocialService {
    enum SocialError: LocalizedError {
        case notSignedIn
        case inviteExpired
        case notFound
        case removedFromGroup
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in (YOU → Settings) to do this. Logging works without it."
            case .inviteExpired: return "That invite expired. Ask for a new one."
            case .notFound: return "That link doesn't point anywhere any more."
            case .removedFromGroup: return "The owner removed you from this group."
            case .serverError(let m): return m
            }
        }
    }

    let store: Store
    private var uid: UserID?
    private var db: Firestore { Firestore.firestore() }
    private lazy var functions = Functions.functions(region: FirebaseConfig.functionsRegion)

    init(store: Store) { self.store = store }

    func setUser(_ uid: UserID?) { self.uid = uid }

    private func me() throws -> UserID {
        guard FirebaseConfig.isConfigured, let uid else { throw SocialError.notSignedIn }
        return uid
    }

    private func call(_ name: String, _ data: [String: Any]) async throws -> [String: Any] {
        _ = try me()
        do {
            let result = try await functions.httpsCallable(name).call(data)
            return (result.data as? [String: Any]) ?? [:]
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) {
                switch code {
                case .notFound: throw SocialError.notFound
                case .permissionDenied: throw SocialError.removedFromGroup
                case .unauthenticated: throw SocialError.notSignedIn
                default: break
                }
                log.error("\(name, privacy: .public) failed: \(ns.localizedDescription, privacy: .public)")
                throw SocialError.serverError(ns.localizedDescription)
            }
            throw error
        }
    }

    // MARK: - Friends

    /// Who is behind an invite token (for links without the inviter's id, or to double-check one).
    func resolveInvite(token: String) async throws -> UserID {
        _ = try me()
        let snap = try await db.document(FirestorePaths.publicInvite(token)).getDocument()
        guard let d = snap.data(), let uid = d["uid"] as? String else { throw SocialError.inviteExpired }
        if let exp = (d["expiresAt"] as? Timestamp)?.dateValue(), exp < Date() { throw SocialError.inviteExpired }
        return uid
    }

    /// B side: creates the request record. Returns its id.
    func sendFriendRequest(to other: UserID, inviteToken: String) async throws -> String {
        let me = try me()
        let doc = db.collection("friendRequests").document()
        guard let person = try? FirestoreCoder.encoder.encode(store.meRef) else { throw SocialError.serverError("Couldn't encode profile.") }
        try await doc.setData([
            "from": me, "to": other, "inviteToken": inviteToken, "fromPerson": person,
            "status": "pending", "createdAt": FieldValue.serverTimestamp(),
        ])
        return doc.documentID
    }

    /// A side: accepting creates the friendship (the request is cleaned up server-side).
    func acceptFriendRequest(requestID: String, from other: UserID) async throws {
        let me = try me()
        try await db.document(FirestorePaths.friendship(me, other)).setData([
            "members": [me, other], "acceptedBy": me, "requestID": requestID, "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func deleteFriendRequest(_ requestID: String) async {
        guard (try? me()) != nil else { return }
        try? await db.document("friendRequests/\(requestID)").delete()
    }

    /// Unfriend (or block): the friendship record goes; both sides lose access at once.
    func unfriend(_ other: UserID) async {
        guard let me = try? me() else { return }
        try? await db.document(FirestorePaths.friendship(me, other)).delete()
    }

    /// Mirrors the block list as `users/{me}/blocks/{uid}` documents, which the rules consult.
    func syncBlocks(_ blocked: Set<UserID>) async {
        guard let me = try? me() else { return }
        let existing = (try? await db.collection("users/\(me)/blocks").getDocuments())?.documents.map(\.documentID) ?? []
        let batch = db.batch()
        for uid in blocked where !existing.contains(uid) {
            batch.setData(["at": FieldValue.serverTimestamp()], forDocument: db.document("users/\(me)/blocks/\(uid)"))
        }
        for uid in existing where !blocked.contains(uid) {
            batch.deleteDocument(db.document("users/\(me)/blocks/\(uid)"))
        }
        try? await batch.commit()
    }

    // MARK: - Groups

    struct GroupPreview {
        var gid: UUID
        var name: String
        var object: GroupObject
        var color: IdentityColor
        var ownerID: UserID?
    }

    /// What a join code points at (for the "ASK TO JOIN?" sheet).
    func resolveGroupInvite(code: String) async throws -> GroupPreview {
        _ = try me()
        let snap = try await db.document(FirestorePaths.groupInvite(code)).getDocument()
        guard let d = snap.data(), let gidString = d["gid"] as? String, let gid = UUID(uuidString: gidString) else { throw SocialError.notFound }
        return GroupPreview(gid: gid, name: (d["name"] as? String) ?? "a group",
                            object: GroupObject(rawValue: (d["object"] as? String) ?? "") ?? .toilet,
                            color: IdentityColor(rawValue: (d["color"] as? String) ?? "") ?? .violet,
                            ownerID: d["ownerID"] as? String)
    }

    enum JoinOutcome { case requested, member }

    /// Asks to join. The owner approves (or not); banned people are refused by the server.
    func requestJoin(code: String) async throws -> (JoinOutcome, GroupPreview) {
        let r = try await call("requestJoinGroup", ["code": code])
        guard let gidString = r["gid"] as? String, let gid = UUID(uuidString: gidString) else { throw SocialError.notFound }
        let preview = GroupPreview(gid: gid, name: (r["name"] as? String) ?? "a group",
                                   object: GroupObject(rawValue: (r["object"] as? String) ?? "") ?? .toilet,
                                   color: IdentityColor(rawValue: (r["color"] as? String) ?? "") ?? .violet, ownerID: r["ownerID"] as? String)
        return ((r["status"] as? String) == "member" ? .member : .requested, preview)
    }

    func cancelJoinRequest(gid: UUID) async throws { _ = try await call("cancelJoinRequest", ["gid": gid.uuidString]) }
    func approveJoin(gid: UUID, uid: UserID) async throws { _ = try await call("approveJoin", ["gid": gid.uuidString, "uid": uid]) }
    func declineJoin(gid: UUID, uid: UserID) async throws { _ = try await call("declineJoin", ["gid": gid.uuidString, "uid": uid]) }
    func kick(gid: UUID, uid: UserID) async throws { _ = try await call("kickMember", ["gid": gid.uuidString, "uid": uid]) }
    func unban(gid: UUID, uid: UserID) async throws { _ = try await call("unbanMember", ["gid": gid.uuidString, "uid": uid]) }
    func leaveGroup(gid: UUID) async throws { _ = try await call("leaveGroup", ["gid": gid.uuidString]) }
    func deleteGroup(gid: UUID) async throws { _ = try await call("deleteGroup", ["gid": gid.uuidString]) }

    // MARK: - Ad-hoc spaces

    /// Creates a space I own with the given friends as members.
    func createSpace(id: UUID, kind: SpaceKind, title: String, members: [UserID], expiresAt: Date) async throws {
        let me = try me()
        var ids = [me]
        for m in members where m != me && !ids.contains(m) { ids.append(m) }
        try await db.document("spaces/\(id.uuidString)").setData([
            "id": id.uuidString, "ownerID": me, "kind": kind.rawValue, "title": title, "memberIDs": ids,
            "createdAt": FieldValue.serverTimestamp(), "expiresAt": Timestamp(date: expiresAt),
        ])
    }

    func addSpaceMembers(id: UUID, members: [UserID]) async throws {
        _ = try me()
        guard !members.isEmpty else { return }
        try await db.document("spaces/\(id.uuidString)").updateData(["memberIDs": FieldValue.arrayUnion(members)])
    }

    // MARK: - Account

    /// Deletes everything about me on the server, then the Auth user. The caller wipes the device.
    func deleteAccount() async throws {
        _ = try await call("deleteAccount", [:])
    }
}
