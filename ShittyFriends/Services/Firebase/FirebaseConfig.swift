import FirebaseCore
import FirebaseFirestore
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "firebase")

/// One Firebase project backs sync, friends, groups and alerts (Auth + Firestore + Cloud Functions +
/// Cloud Messaging). The client never reads anybody's data it isn't allowed to: `firebase/firestore.rules`
/// enforces the friend / group visibility model server-side.
enum FirebaseConfig {
    /// Must match the App Group in the app's and both extensions' entitlements.
    static let appGroup = "group.com.sakara.shittyfriends"
    /// Cloud Functions region (must match `setGlobalOptions` in firebase/functions/src/index.ts).
    static let functionsRegion = "asia-northeast1"

    private(set) static var isConfigured = false

    /// Configures Firebase once. Without a `GoogleService-Info.plist` in the bundle (e.g. an `ios-check`
    /// build) the app runs local-only and says so, instead of crashing at launch.
    static func configure() {
        guard !isConfigured, !isRunningUnitTests else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            log.error("GoogleService-Info.plist missing: running local-only (see docs/SETUP.md)")
            return
        }
        FirebaseApp.configure()
        isConfigured = true
    }

    /// True while the app is hosting XCTest.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// Shared container directory used to hand settings to the Notification Service Extension.
    static var appGroupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Where local state lives (Application Support/ShittyFriends).
    static var localDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ShittyFriends", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Firestore document paths for every record the store knows (the schema in `firebase/README.md`).
enum FirestorePaths {
    /// `users/{uid}`, `groups/{gid}` or `spaces/{sid}` for a zone, from my point of view.
    static func root(for zone: ZoneRef, me: UserID) -> String {
        if let gid = zone.groupID { return "groups/\(gid.uuidString)" }
        if let sid = zone.spaceID { return "spaces/\(sid.uuidString)" }
        let owner = zone.isMine ? me : zone.ownerName
        return "users/\(owner)"
    }

    static func participantID(_ sessionID: UUID, _ uid: UserID) -> String { sessionID.uuidString + "_" + uid }
    static func rsvpID(_ partyID: UUID, _ uid: UserID) -> String { partyID.uuidString + "_" + uid }

    static func document(for ref: RecordRef, me: UserID) -> String {
        let root = self.root(for: ref.zone, me: me)
        switch ref {
        case .profile: return root
        case .event(let id): return "\(root)/events/\(id.uuidString)"
        case .achievement(let id): return "\(root)/achievements/\(id.rawValue)"
        case .cosmetic(let id): return "\(root)/cosmetics/\(id.rawValue)"
        case .settings: return "\(root)/private/settings"
        case .friendLink(let id): return "\(root)/friendLinks/\(id.uuidString)"
        case .groupLink(let id): return "\(root)/groupLinks/\(id.uuidString)"
        case .invite(let token): return "\(root)/invites/\(token)"
        case .spaceLink(let zone): return "\(root)/spaceLinks/\(zone.spaceID?.uuidString ?? zone.zoneName)"
        case .groupInfo: return root
        case .member(_, let uid): return "\(root)/members/\(uid)"
        case .joinRequest(_, let uid): return "\(root)/requests/\(uid)"
        case .groupEvent(_, let id): return "\(root)/events/\(id.uuidString)"
        case .pwmSession(_, let id): return "\(root)/sessions/\(id.uuidString)"
        case .participant(_, let sid, let uid): return "\(root)/participants/\(participantID(sid, uid))"
        case .reaction(_, let id): return "\(root)/reactions/\(id.uuidString)"
        case .party(_, let id): return "\(root)/parties/\(id.uuidString)"
        case .rsvp(_, let pid, let uid): return "\(root)/rsvps/\(rsvpID(pid, uid))"
        }
    }

    /// The public, token-addressed copy of a friend invite (anyone signed in can read it to resolve
    /// who is inviting; see rules).
    static func publicInvite(_ token: String) -> String { "invites/\(token)" }
    static func groupInvite(_ code: String) -> String { "groupInvites/\(code)" }
    static func friendship(_ a: UserID, _ b: UserID) -> String { "friendships/\(a < b ? a + "_" + b : b + "_" + a)" }
}

enum CloudAvailability: Equatable {
    case unknown
    case available
    case noAccount
    case notConfigured
    case error(String)

    var isAvailable: Bool { self == .available }

    var message: String? {
        switch self {
        case .unknown, .available: return nil
        case .noAccount: return "Sign in (YOU → Settings) to sync and add friends. Logging still works offline."
        case .notConfigured: return "This build has no Firebase configuration. Logging works; friends don't."
        // The raw reason is logged where it happens; never show backend internals in the UI.
        case .error: return "The server isn't responding right now. Logging still works; we'll sync when it's back."
        }
    }
}
