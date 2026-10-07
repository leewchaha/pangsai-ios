import CloudKit
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "sync")

enum CloudAvailability: Equatable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case error(String)

    var isAvailable: Bool { self == .available }

    var message: String? {
        switch self {
        case .unknown, .available: return nil
        case .noAccount: return "Sign in to iCloud to sync and add friends. Logging still works offline."
        case .restricted: return "iCloud is restricted on this device. Logging works, friends don't."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable. We'll sync when it's back."
        case .error(let s): return "iCloud error: \(s)"
        }
    }
}

/// Two CKSyncEngines: one for my private database (Me, Private, my groups, my session zones)
/// and one for the shared database (friends' Me zones, groups and sessions others own).
@MainActor
final class CloudSync {
    var container: CKContainer { CloudConfig.container }
    let store: Store
    let metadata: RecordMetadataStore
    private(set) var availability: CloudAvailability = .unknown
    var onAvailabilityChange: ((CloudAvailability) -> Void)?
    var onRemoteChangesApplied: (() -> Void)?
    /// My Me/Private zones were deliberately deleted elsewhere ("Delete all my data" on another device,
    /// or iCloud data removed in Settings). The app wipes this device's copy to match.
    var onMyDataDeletedRemotely: (() -> Void)?

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var privateDelegate: EngineDelegate?
    private var sharedDelegate: EngineDelegate?
    private let stateDirectory: URL
    /// Changes made while the engines weren't running yet (offline launch, or before the first
    /// account check finished). Persisted, then handed to the engines as soon as they start.
    private var queued: [QueuedChange]
    /// After a replay, the queue file is kept until both engines have persisted their own state.
    private var replayAwaitingState: Set<CloudDatabaseScope> = []
    /// Zones this device deleted this session: never recreate them from a failed save.
    private var deletedZones: Set<ZoneRef> = []

    init(store: Store, directory: URL) {
        self.store = store
        self.stateDirectory = directory
        self.metadata = RecordMetadataStore(directory: directory)
        let url = directory.appendingPathComponent("engine-queue.json")
        self.queued = (try? JSONDecoder().decode([QueuedChange].self, from: Data(contentsOf: url))) ?? []
    }

    // MARK: - Lifecycle

    /// Checks the iCloud account, learns my user record name, and starts both engines.
    func start() async {
        if CloudConfig.isRunningUnitTests {
            setAvailability(.error("Disabled while running unit tests"))
            return
        }
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount:
                setAvailability(.noAccount); return
            case .restricted:
                setAvailability(.restricted); return
            case .temporarilyUnavailable:
                setAvailability(.temporarilyUnavailable); return
            case .couldNotDetermine:
                setAvailability(.error("Could not determine iCloud status")); return
            @unknown default:
                setAvailability(.error("Unknown iCloud status")); return
            }
            if let known = store.my.userID, known != UserID.localMe {
                // Already signed in on this device before: start syncing right away (works offline;
                // the engines send once the network is back) and confirm the account afterwards.
                startEngines()
                setAvailability(.available)
                ensureBaseZones()
                if let current = try? await container.userRecordID(), current.recordName != known {
                    switchAccount(to: current.recordName)
                }
                return
            }
            let userID = try await container.userRecordID()
            store.setUserID(userID.recordName)
            startEngines()
            setAvailability(.available)
            ensureBaseZones()
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            setAvailability(.error(error.localizedDescription))
        }
    }

    /// A different iCloud account than the data on this device: start clean.
    private func switchAccount(to recordName: String) {
        log.info("iCloud account switched; resetting local state")
        stopEngines()
        store.resetForAccountChange(keepOnboarding: false)
        metadata.removeAll()
        deleteEngineStates()
        clearQueue()
        UserDefaults.standard.removeObject(forKey: "sf.initialUploadDone")
        store.setUserID(recordName)
        startEngines()
        ensureBaseZones()
    }

    private func stopEngines() {
        privateEngine = nil
        sharedEngine = nil
        privateDelegate = nil
        sharedDelegate = nil
    }

    private func setAvailability(_ a: CloudAvailability) {
        availability = a
        onAvailabilityChange?(a)
    }

    private func startEngines() {
        guard privateEngine == nil else { return }
        let pd = EngineDelegate(scope: .private, sync: self)
        let sd = EngineDelegate(scope: .shared, sync: self)
        privateDelegate = pd
        sharedDelegate = sd
        privateEngine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: loadState(.private), delegate: pd))
        sharedEngine = CKSyncEngine(CKSyncEngine.Configuration(database: container.sharedCloudDatabase, stateSerialization: loadState(.shared), delegate: sd))
        replayQueue()
    }

    private func engine(_ scope: CloudDatabaseScope) -> CKSyncEngine? {
        scope == .private ? privateEngine : sharedEngine
    }

    private func ensureBaseZones() {
        guard let e = privateEngine else { return }
        e.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: ZoneRef.me.zoneID)),
            .saveZone(CKRecordZone(zoneID: ZoneRef.privateZone.zoneID))
        ])
        // Re-upload anything that might never have made it (first launch after offline use).
        if !UserDefaults.standard.bool(forKey: "sf.initialUploadDone") {
            uploadEverythingMine()
            UserDefaults.standard.set(true, forKey: "sf.initialUploadDone")
        }
    }

    /// Queue every record I own (used on first sign-in and after account resets).
    func uploadEverythingMine() {
        var refs: [RecordRef] = []
        let my = store.my
        if my.profile != nil { refs.append(.profile) }
        refs += my.events.keys.map { .event($0) }
        refs += my.achievements.keys.map { .achievement($0) }
        refs += my.cosmetics.keys.map { .cosmetic($0) }
        refs.append(.settings)
        refs += my.friendLinks.keys.map { .friendLink($0) }
        refs += my.groupLinks.keys.map { .groupLink($0) }
        refs += my.invites.keys.map { .invite($0) }
        refs += my.spaceLinks.keys.map { .spaceLink($0) }
        for ref in refs { save(ref) }
    }

    // MARK: - Queueing

    func save(_ ref: RecordRef) {
        apply(QueuedChange(.save, zone: ref.zone, recordName: ref.recordName))
    }

    func delete(_ ref: RecordRef) {
        apply(QueuedChange(.delete, zone: ref.zone, recordName: ref.recordName))
    }

    /// Make sure a zone I own exists before records go into it.
    func ensureZone(_ zone: ZoneRef) {
        guard zone.isMine else { return }
        apply(QueuedChange(.saveZone, zone: zone))
    }

    func deleteZone(_ zone: ZoneRef) {
        guard zone.isMine else { return }
        if zone == .me || zone == .privateZone {
            // Remember it, so the deletion echoing back from iCloud isn't mistaken for another device's.
            UserDefaults.standard.set(Date(), forKey: Self.selfDeletedBaseZonesKey)
        }
        dropPendingRecordChanges(in: zone)
        apply(QueuedChange(.deleteZone, zone: zone))
        metadata.removeZone(zone.zoneID)
    }

    static let selfDeletedBaseZonesKey = "sf.selfDeletedBaseZonesAt"

    /// A zone that's going away must not have record saves behind it (they'd fail with zoneNotFound
    /// and the retry path would recreate the zone).
    private func dropPendingRecordChanges(in zone: ZoneRef) {
        deletedZones.insert(zone)
        let before = queued.count
        queued.removeAll { $0.zone == zone && ($0.kind == .save || $0.kind == .delete) }
        if queued.count != before { persistQueue() }
        guard let e = engine(zone.isMine ? .private : .shared) else { return }
        let stale = e.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.zoneID == zone.zoneID
            @unknown default: return false
            }
        }
        if !stale.isEmpty { e.state.remove(pendingRecordZoneChanges: stale) }
    }

    /// Leaves a zone someone else shared with me. Deleting a zone in the shared database removes
    /// me as a participant; the owner's data is untouched.
    func leaveZone(_ zone: ZoneRef) {
        guard !zone.isMine else { return }
        dropPendingRecordChanges(in: zone)
        apply(QueuedChange(.deleteZone, zone: zone))
        metadata.removeZone(zone.zoneID)
    }

    /// Hands a change to the right engine, or queues it (persisted) until the engines start.
    private func apply(_ change: QueuedChange) {
        if change.kind == .saveZone || change.kind == .save { deletedZones.remove(change.zone) }
        guard let e = engine(change.zone.isMine ? .private : .shared) else {
            // Last write wins: a later save/delete of the same record (or zone) replaces the earlier one.
            queued.removeAll { $0.supersededBy(change) }
            queued.append(change)
            persistQueue()
            return
        }
        Self.add(change, to: e)
    }

    private static func add(_ change: QueuedChange, to e: CKSyncEngine) {
        let zoneID = change.zone.zoneID
        switch change.kind {
        case .save:
            guard let name = change.recordName else { return }
            e.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        case .delete:
            guard let name = change.recordName else { return }
            e.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        case .saveZone:
            e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        case .deleteZone:
            e.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        }
    }

    private func replayQueue() {
        guard !queued.isEmpty else { return }
        let pending = queued
        queued = []
        // Keep the file until both engines have saved state containing these changes.
        replayAwaitingState = [.private, .shared]
        log.info("replaying \(pending.count) changes queued before sync started")
        for change in pending {
            // Zones must be queued before records that go into them; CKSyncEngine sends database
            // changes first, so plain order is fine.
            if let e = engine(change.zone.isMine ? .private : .shared) { Self.add(change, to: e) }
        }
    }

    private var queueURL: URL { stateDirectory.appendingPathComponent("engine-queue.json") }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(queued) { try? data.write(to: queueURL, options: [.atomic]) }
    }

    private func clearQueue() {
        queued = []
        replayAwaitingState = []
        try? FileManager.default.removeItem(at: queueURL)
    }

    /// Forget everything local about sync (used by "Delete all my data").
    func resetLocalSyncState() {
        metadata.removeAll()
        clearQueue()
    }

    /// Creates a zone right now (needed before a share can be saved for it).
    func createZoneNow(_ zone: ZoneRef) async throws {
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: zone.zoneID)], deleting: [])
    }

    // MARK: - Fetch / send on demand

    func fetchAll() async {
        for e in [privateEngine, sharedEngine].compactMap({ $0 }) {
            do { try await e.fetchChanges() } catch { log.error("fetch failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func fetchShared() async {
        guard let e = sharedEngine else { return }
        do { try await e.fetchChanges() } catch { log.error("shared fetch failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Fast path while a live session screen is open.
    func fetch(zone: ZoneRef) async {
        guard let e = engine(zone.isMine ? .private : .shared) else { return }
        do {
            try await e.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zone.zoneID])))
        } catch {
            log.error("zone fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendAll() async {
        for e in [privateEngine, sharedEngine].compactMap({ $0 }) {
            do { try await e.sendChanges() } catch { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - State persistence

    private func stateURL(_ scope: CloudDatabaseScope) -> URL {
        stateDirectory.appendingPathComponent("engine-\(scope.rawValue).json")
    }

    private func loadState(_ scope: CloudDatabaseScope) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL(scope)) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    fileprivate func saveState(_ s: CKSyncEngine.State.Serialization, scope: CloudDatabaseScope) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL(scope), options: [.atomic])
        }
    }

    private func deleteEngineStates() {
        try? FileManager.default.removeItem(at: stateURL(.private))
        try? FileManager.default.removeItem(at: stateURL(.shared))
    }

    // MARK: - Event handling (called by the delegates on the main actor)

    fileprivate func handle(_ event: CKSyncEngine.Event, scope: CloudDatabaseScope, engine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let e):
            // A replaced engine (after an account switch) must not overwrite the new engine's state.
            guard engine === self.engine(scope) else { return }
            saveState(e.stateSerialization, scope: scope)
            if replayAwaitingState.remove(scope) != nil, replayAwaitingState.isEmpty, queued.isEmpty {
                try? FileManager.default.removeItem(at: queueURL)
            }

        case .accountChange(let e):
            // Both engines report the same account change; handle it once.
            guard scope == .private, engine === privateEngine else { return }
            handleAccountChange(e)

        case .fetchedDatabaseChanges(let e):
            var changes: [RemoteChange] = []
            var baseZoneDeleted = false
            for d in e.deletions {
                metadata.removeZone(d.zoneID)
                let zone = ZoneRef(d.zoneID)
                if zone.isMine && (zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private) {
                    // Per the CKSyncEngine docs, for every reason (deleted by another of my devices,
                    // purged in Settings, or an encrypted-data reset) local data must be deleted and
                    // never re-sent. The only exception is our own "Delete all my data" echoing back.
                    if d.reason == .deleted && Self.deletedByThisDeviceRecently { continue }
                    baseZoneDeleted = true
                    continue
                }
                changes.append(.zoneDeleted(zone))
            }
            store.apply(changes)
            if baseZoneDeleted {
                // Drop anything still queued for those zones so nothing is re-sent.
                dropPendingRecordChanges(in: .me)
                dropPendingRecordChanges(in: .privateZone)
                onMyDataDeletedRemotely?()
            }

        case .fetchedRecordZoneChanges(let e):
            var changes: [RemoteChange] = []
            for m in e.modifications {
                let record = m.record
                metadata.update(record)
                if let decoded = RecordCoder.decode(record) {
                    let zone = ZoneRef(record.recordID.zoneID)
                    if let writer = lastWriter(of: record) {
                        changes.append(.upsertFrom(decoded, zone: zone, writer: writer))
                    } else {
                        changes.append(.upsert(decoded, zone: zone))
                    }
                }
            }
            for d in e.deletions {
                metadata.remove(d.recordID)
                let zone = ZoneRef(d.recordID.zoneID)
                if let ref = RecordRef.parse(recordName: d.recordID.recordName, zone: zone) {
                    changes.append(.delete(ref, zone: zone))
                }
            }
            store.apply(changes)
            if !changes.isEmpty { onRemoteChangesApplied?() }

        case .sentRecordZoneChanges(let e):
            handleSent(e, engine: engine)

        case .sentDatabaseChanges(let e):
            for failure in e.failedZoneSaves {
                log.error("zone save failed \(failure.zone.zoneID.zoneName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    /// The iCloud user who last saved `record` ("__defaultOwner__" means me).
    private func lastWriter(of record: CKRecord) -> UserID? {
        guard let name = record.lastModifiedUserRecordID?.recordName else { return nil }
        if name == CKCurrentUserDefaultName { return store.userID }
        return name
    }

    /// True for a day after this device deleted its own Me/Private zones.
    private static var deletedByThisDeviceRecently: Bool {
        guard let at = UserDefaults.standard.object(forKey: selfDeletedBaseZonesKey) as? Date else { return false }
        return Date().timeIntervalSince(at) < 24 * 3600
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in e.savedRecords { metadata.update(record) }
        for id in e.deletedRecordIDs { metadata.remove(id) }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zones: [CKSyncEngine.PendingDatabaseChange] = []
        var remote: [RemoteChange] = []

        for failure in e.failedRecordSaves {
            let record = failure.record
            let id = record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { continue }
                metadata.update(server)
                let serverDate = RecordCoder.updatedAt(server) ?? .distantPast
                let localDate = RecordCoder.updatedAt(record) ?? .distantPast
                if serverDate > localDate, let decoded = RecordCoder.decode(server) {
                    // Server is newer: take it.
                    remote.append(.upsert(decoded, zone: ZoneRef(id.zoneID)))
                } else {
                    // Ours is newer: retry on top of the server's change tag.
                    retry.append(.saveRecord(id))
                }
            case .zoneNotFound:
                let zone = ZoneRef(id.zoneID)
                metadata.remove(id)
                if zone.isMine && deletedZones.contains(zone) {
                    // The zone was deleted on purpose; drop the save.
                    continue
                } else if zone.isMine {
                    zones.append(.saveZone(CKRecordZone(zoneID: id.zoneID)))
                    retry.append(.saveRecord(id))
                } else {
                    // A shared zone we no longer have access to.
                    remote.append(.zoneDeleted(zone))
                }
            case .unknownItem:
                metadata.remove(id)
                retry.append(.saveRecord(id))
            case .permissionFailure, .participantMayNeedVerification:
                log.error("permission failure saving \(id.recordName, privacy: .public)")
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled:
                break // the engine retries these itself
            default:
                log.error("save failed \(id.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for (id, error) in e.failedRecordDeletes {
            if error.code == .unknownItem || error.code == .zoneNotFound {
                metadata.remove(id)
            }
        }
        if !zones.isEmpty { engine.state.add(pendingDatabaseChanges: zones) }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        if !remote.isEmpty { store.apply(remote) }
    }

    private func handleAccountChange(_ e: CKSyncEngine.Event.AccountChange) {
        switch e.changeType {
        case .signIn:
            uploadEverythingMine()
        case .signOut, .switchAccounts:
            stopEngines()
            store.resetForAccountChange(keepOnboarding: false)
            metadata.removeAll()
            deleteEngineStates()
            clearQueue()
            UserDefaults.standard.removeObject(forKey: "sf.initialUploadDone")
            setAvailability(.unknown)
            Task { await self.start() }
        @unknown default:
            break
        }
    }

    // MARK: - Batches

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        var missing: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in pending {
            guard case .saveRecord(let id) = change else { continue }
            let zone = ZoneRef(id.zoneID)
            guard let ref = RecordRef.parse(recordName: id.recordName, zone: zone),
                  let record = RecordCoder.record(for: ref, store: store, base: metadata.baseRecord(for: id)) else {
                missing.append(change)
                continue
            }
            recordsByID[id] = record
        }
        if !missing.isEmpty { engine.state.remove(pendingRecordZoneChanges: missing) }
        let usable = pending.filter { change in
            if case .saveRecord(let id) = change { return recordsByID[id] != nil }
            return true
        }
        guard !usable.isEmpty else { return nil }
        let records = recordsByID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: usable) { id in records[id] }
    }
}

/// Bridges CKSyncEngine callbacks onto the main actor.
private final class EngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let scope: CloudDatabaseScope
    weak var sync: CloudSync?

    init(scope: CloudDatabaseScope, sync: CloudSync) {
        self.scope = scope
        self.sync = sync
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = self.scope
        await MainActor.run { [weak sync] in
            sync?.handle(event, scope: scope, engine: syncEngine)
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let sync = sync else { return nil }
        return await sync.nextBatch(context, engine: syncEngine)
    }
}

/// A change waiting for the sync engines to start. Stored by zone + record name so it survives relaunch.
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
            return true // the zone and everything in it is going away
        default:
            return false
        }
    }
}
