import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "data")

extension AppModel {
    /// Builds the export zip in a temporary folder and returns its URL (for the share sheet).
    func makeExport() throws -> URL {
        let data = try ExportBuilder.zip(store: store)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ShittyFriends Export \(f.string(from: Date())).zip")
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Imports poop-history.json from a previous export. Returns the number of new poops.
    func importHistory(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let events = try ExportBuilder.parseHistory(data)
        return store.importHistory(events)
    }

    /// Deletes everything this app stored for me: local files, my iCloud zones (history, settings,
    /// groups I own, invites), my pings, and my membership in other people's zones.
    func deleteAllMyData() async {
        busy = "Deleting…"
        isDeletingAll = true
        defer {
            busy = nil
            isDeletingAll = false
        }
        let userID = store.userID
        // Leave zones others shared with me and revoke what I shared.
        for link in store.my.friendLinks.values {
            if let uid = link.userID { shares.leave(ZoneRef(ownerName: uid, zoneName: ZoneNames.me)) }
        }
        for link in store.my.groupLinks.values {
            if link.isOwner { shares.deleteOwned(link.zone) } else {
                store.removeGroupLocal(link.id)
                shares.leave(link.zone)
            }
        }
        for space in store.my.spaceLinks.values {
            if space.isOwner { shares.deleteOwned(space.zone) } else { shares.leave(space.zone) }
        }
        for token in store.my.invites.keys { await shares.deleteInviteCard(token: token) }
        // Deleting my zones also deletes their shares (friends lose access to my history).
        shares.deleteOwned(.me)
        shares.deleteOwned(.privateZone)
        shares.deleteOwned(ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.invites))
        await cloud.sendAll()
        pings.cleanupExpired(now: .distantFuture)
        await pings.deleteAllSubscriptions()
        wipeLocal(keepingUserID: userID)
        log.info("all data deleted")
    }

    /// Another device deleted my iCloud data (or the user removed it in Settings): match it here.
    func wipeAfterRemoteDeletion() {
        guard !isDeletingAll else { return }
        log.info("my zones were deleted elsewhere; wiping local copy")
        let userID = store.userID
        Task { await pings.deleteAllSubscriptions() }
        wipeLocal(keepingUserID: userID)
        showSession = false
        sheet = nil
        info("DATA DELETED", "Your ShittyFriends data was deleted from iCloud.")
    }

    /// Clears everything on this device but stays signed in to the same iCloud account,
    /// so the app keeps working (onboarding starts again) without a relaunch.
    private func wipeLocal(keepingUserID userID: UserID?) {
        pings.reset()
        notifications.clearAll()
        store.resetForAccountChange(keepOnboarding: false)
        persistence.wipe()
        cloud.resetLocalSyncState()
        UserDefaults.standard.removeObject(forKey: "sf.initialUploadDone")
        if let userID { store.setUserID(userID) }
        saveNow()
    }
}
