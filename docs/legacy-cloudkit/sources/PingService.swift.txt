import CloudKit
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "pings")

/// The anonymous ping channel in the CloudKit *public* database.
///
/// A `Ping` record holds only: recipient token (`to`), kind, optional sender group token (`from`),
/// an AES-GCM sealed payload (`ref`) and an expiry (`exp`). No handles, no locations, no history.
/// Senders delete their pings when they expire or become stale (DONE / delete).
@MainActor
final class PingService {
    var container: CKContainer { CloudConfig.container }
    let store: Store
    private let sealer = AESSealer()
    private let fileURL: URL
    private var state: State
    private var subscriptionTask: Task<Void, Never>?

    /// Device-local bookkeeping.
    struct State: Codable {
        struct Sent: Codable, Hashable {
            var recordName: String
            var eventID: UUID?
            var expiresAt: Date
        }
        /// Pings I created and must delete later.
        var sent: [Sent] = []
        /// Incoming pings already handled (record name -> expiry, for pruning).
        var processed: [String: Date] = [:]
        /// Fingerprint of the last subscription set saved successfully.
        var subscriptionFingerprint: String?
        var subscriptionsSavedAt: Date?
    }

    init(store: Store, directory: URL) {
        self.store = store
        self.fileURL = directory.appendingPathComponent("pings.json")
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    private var db: CKDatabase { container.publicCloudDatabase }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: fileURL, options: [.atomic]) }
    }

    // MARK: - Sending

    func send(_ intent: PingIntent) {
        let pings = PingPlanner.pings(for: intent, store: store, now: Date())
        send(pings)
    }

    func send(_ pings: [OutgoingPing]) {
        guard !pings.isEmpty, store.userID != nil else { return }
        var records: [CKRecord] = []
        var sent: [State.Sent] = []
        for p in pings {
            guard let ref = try? sealer.seal(p.payload, keyBase64URL: p.key) else {
                log.error("could not seal ping \(p.kind.rawValue, privacy: .public)")
                continue
            }
            let id = CKRecord.ID(recordName: "P-" + UUID().uuidString)
            let r = CKRecord(recordType: PingField.recordType, recordID: id)
            r[PingField.to] = p.to as CKRecordValue
            r[PingField.kind] = p.kind.rawValue as CKRecordValue
            if let from = p.from { r[PingField.from] = from as CKRecordValue }
            r[PingField.ref] = ref as CKRecordValue
            r[PingField.exp] = p.expiresAt as CKRecordValue
            records.append(r)
            sent.append(State.Sent(recordName: id.recordName, eventID: p.eventID, expiresAt: p.expiresAt))
        }
        guard !records.isEmpty else { return }
        Task {
            do {
                // Non-atomic: one bad record must not block the others.
                let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
                var ok = Set<String>()
                for (id, r) in result.saveResults {
                    switch r {
                    case .success: ok.insert(id.recordName)
                    case .failure(let e): log.error("ping save failed: \(e.localizedDescription, privacy: .public)")
                    }
                }
                self.state.sent += sent.filter { ok.contains($0.recordName) }
                self.persist()
            } catch {
                log.error("ping batch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Withdraw pings about an event (e.g. "is pooping" after DONE, or after delete/undo).
    func cancel(eventID: UUID) {
        let ids = state.sent.filter { $0.eventID == eventID }.map { CKRecord.ID(recordName: $0.recordName) }
        guard !ids.isEmpty else { return }
        state.sent.removeAll { $0.eventID == eventID }
        persist()
        delete(ids)
    }

    /// Delete my expired pings. Cheap; run on launch and foreground.
    func cleanupExpired(now: Date = Date()) {
        let expired = state.sent.filter { $0.expiresAt < now }
        state.sent.removeAll { $0.expiresAt < now }
        state.processed = state.processed.filter { $0.value > now.addingTimeInterval(-24 * 3600) }
        persist()
        delete(expired.map { CKRecord.ID(recordName: $0.recordName) })
    }

    private func delete(_ ids: [CKRecord.ID]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                _ = try await db.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            } catch {
                log.error("ping delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Receiving

    /// Unprocessed, unexpired pings addressed to any of my tokens.
    func fetchIncoming(now: Date = Date()) async -> [IncomingPing] {
        let tokens = PingPlanner.listeningTokens(store: store, now: now)
        guard !tokens.isEmpty else { return [] }
        var out: [IncomingPing] = []
        var start = 0
        while start < tokens.count {
            let chunk = Array(tokens[start..<min(start + PingPlanner.tokensPerSubscription, tokens.count)])
            start += PingPlanner.tokensPerSubscription
            let query = CKQuery(recordType: PingField.recordType, predicate: NSPredicate(format: "%K IN %@", PingField.to, chunk))
            do {
                let (results, _) = try await db.records(matching: query, inZoneWith: nil, desiredKeys: [PingField.to, PingField.kind, PingField.from, PingField.ref, PingField.exp], resultsLimit: 200)
                for (_, result) in results {
                    guard case .success(let r) = result, let ping = Self.decode(r) else { continue }
                    if ping.expiresAt < now || state.processed[ping.recordName] != nil { continue }
                    out.append(ping)
                }
            } catch {
                log.error("ping fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return out.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    static func decode(_ r: CKRecord) -> IncomingPing? {
        guard let to = r[PingField.to] as? String,
              let kindRaw = r[PingField.kind] as? String, let kind = PingKind(rawValue: kindRaw) else { return nil }
        let exp = (r[PingField.exp] as? Date) ?? (r.creationDate ?? Date()).addingTimeInterval(kind.lifetime)
        return IncomingPing(recordName: r.recordID.recordName, to: to, kind: kind, from: r[PingField.from] as? String, ref: r[PingField.ref] as? String, expiresAt: exp, createdAt: r.creationDate)
    }

    func markProcessed(_ ping: IncomingPing) {
        state.processed[ping.recordName] = ping.expiresAt
        persist()
    }

    func process(_ ping: IncomingPing) -> PingAction {
        PingPlanner.process(ping, store: store, sealer: sealer, now: Date())
    }

    // MARK: - Subscriptions

    /// Debounced: preference changes often come in bursts.
    func scheduleSubscriptionRefresh() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshSubscriptions(force: false)
        }
    }

    func refreshSubscriptions(force: Bool) async {
        guard store.userID != nil else { return }
        let specs = PingPlanner.subscriptionSpecs(store: store, now: Date())
        let fingerprint = specs.map { "\($0.id)=\($0.kinds.map(\.rawValue).joined(separator: ","))|\($0.tokens.joined(separator: ","))" }.joined(separator: ";")
        let fresh = state.subscriptionsSavedAt.map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
        if !force, fresh, fingerprint == state.subscriptionFingerprint { return }
        do {
            let existing = try await db.allSubscriptions().map(\.subscriptionID).filter { $0.hasPrefix(SubscriptionSpec.idPrefix) }
            let wanted = Set(specs.map(\.id))
            let toDelete = existing.filter { !wanted.contains($0) }
            let toSave = specs.map(Self.subscription)
            _ = try await db.modifySubscriptions(saving: toSave, deleting: toDelete)
            state.subscriptionFingerprint = fingerprint
            state.subscriptionsSavedAt = Date()
            persist()
            log.info("saved \(toSave.count) ping subscriptions, deleted \(toDelete.count)")
        } catch {
            // Typical first-run cause: the Ping record type/indexes aren't deployed yet (see docs/SETUP.md §4).
            log.error("subscription refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func subscription(_ spec: SubscriptionSpec) -> CKQuerySubscription {
        let predicate = NSPredicate(format: "%K IN %@ AND %K IN %@", PingField.to, spec.tokens, PingField.kind, spec.kinds.map(\.rawValue))
        let sub = CKQuerySubscription(recordType: PingField.recordType, predicate: predicate, subscriptionID: spec.id, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        // Fallback text if the Notification Service Extension can't run; it normally rewrites everything.
        info.title = "ShittyFriends"
        info.alertBody = "Something happened. 💩"
        info.soundName = "default"
        info.shouldSendMutableContent = true
        info.desiredKeys = [PingField.to, PingField.kind, PingField.from, PingField.ref]
        info.category = NotificationCategory.general
        sub.notificationInfo = info
        return sub
    }

    /// Removes every ping subscription for this iCloud user (delete-all / remote wipe).
    func deleteAllSubscriptions() async {
        do {
            let ids = try await db.allSubscriptions().map(\.subscriptionID).filter { $0.hasPrefix(SubscriptionSpec.idPrefix) }
            guard !ids.isEmpty else { return }
            _ = try await db.modifySubscriptions(saving: [], deleting: ids)
            state.subscriptionFingerprint = nil
            state.subscriptionsSavedAt = nil
            persist()
        } catch {
            log.error("subscription delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Directory for the Notification Service Extension

    func writeDirectory() {
        guard let dir = CloudConfig.appGroupDirectory else {
            log.error("App Group container unavailable; notification text will be generic")
            return
        }
        do {
            try PingPlanner.directory(store: store, now: Date()).write(to: dir)
        } catch {
            log.error("directory write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget everything (account switch / delete all data).
    func reset() {
        state = State()
        persist()
        if let dir = CloudConfig.appGroupDirectory {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(PingDirectory.fileName))
        }
    }
}
