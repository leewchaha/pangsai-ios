import Compression
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

    /// Imports a previous export: the .zip itself, or the poop-history.json inside it.
    /// Returns the number of new poops.
    func importHistory(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data = try Data(contentsOf: url)
        if ZipReader.looksLikeZip(data) {
            data = try ZipReader.file(named: "poop-history.json", in: data, inflate: AppModel.inflateRawDeflate)
        }
        let events = try ExportBuilder.parseHistory(data)
        return store.importHistory(events)
    }

    /// Raw DEFLATE (zip method 8) via Apple's Compression; for exports the user re-zipped in Files/Finder.
    nonisolated static func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize < 200_000_000, !data.isEmpty else { return nil }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }

    // MARK: - Account

    /// Signs out. History stays on this phone (local-first) and in the account; sync, friends and alerts
    /// pause until someone signs in. A *different* account signing in later clears this phone first
    /// (see `AppModel.authChanged`), so histories never mix.
    func signOut() async {
        busy = "Signing out…"
        defer { busy = nil }
        flushAllPending()
        await push.unregister()
        auth.signOut()
        sync.stop()
    }

    /// Deletes everything about me: on the server (history, friendships, memberships, groups I own, my
    /// sign-in) and on this device.
    func deleteAllMyData() async {
        busy = "Deleting…"
        isDeletingAll = true
        defer {
            busy = nil
            isDeletingAll = false
        }
        do {
            try await social.deleteAccount()
        } catch {
            self.error("Couldn't delete on the server", error)
            return
        }
        await push.unregister()
        auth.signOut()
        wipeLocal()
        showSession = false
        sheet = nil
        log.info("all data deleted")
    }

    private func flushAllPending() {
        saveNow()
        sync.sendAll()
    }

    /// Clears everything on this device (onboarding starts again).
    private func wipeLocal() {
        push.reset()
        notifications.clearAll()
        sync.stop()
        store.resetForAccountChange(keepOnboarding: false)
        store.setUserID(nil)
        persistence.wipe()
        sync.resetLocalSyncState()
        UserDefaults.standard.removeObject(forKey: "sf.initialUploadDone")
        saveNow()
    }
}
