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
    let container: CKContainer
    let store: Store
    let metadata: RecordMetadataStore
    private(set) var availability: CloudAvailability = .unknown
    var onAvailabilityChange: ((CloudAvailability) -> Void)?
    var onRemoteChangesApplied: (() -> Void)?

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var privateDelegate: EngineDelegate?
    private var sharedDelegate: EngineDelegate?
    private let stateDirectory: URL

    init(container: CKContainer, store: Store, directory: URL) {
        self.container = container
        self.store = store
        self.stateDirectory = directory
        self.metadata = RecordMetadataStore(directory: directory)
    }

    // MARK: - Lifecycle

    /// Checks the iCloud account, learns my user record name, and starts both engines.
    func start() async {
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
            let userID = try await container.userRecordID()
            if let previous = store.my.userID, previous != userID.recordName, previous != UserID.localMe {
                // Different iCloud account than the data on this device: start clean.
                log.info("iCloud account switched; resetting local state")
                store.resetForAccountChange(keepOnboarding: false)
                metadata.removeAll()
                deleteEngineStates()
            }
            store.setUserID(userID.recordName)
            startEngines()
            setAvailability(.available)
            ensureBaseZones()
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            setAvailability(.error(error.localizedDescription))
        }
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
        for ref in refs { save(ref) }
    }

    // MARK: - Queueing

    func save(_ ref: RecordRef) {
        guard let e = engine(ref.isPrivateDatabase ? .private : .shared) else { return }
        e.state.add(pendingRecordZoneChanges: [.saveRecord(ref.recordID)])
    }

    func delete(_ ref: RecordRef) {
        guard let e = engine(ref.isPrivateDatabase ? .private : .shared) else { return }
        e.state.add(pendingRecordZoneChanges: [.deleteRecord(ref.recordID)])
    }

    /// Make sure a zone I own exists before records go into it.
    func ensureZone(_ zone: ZoneRef) {
        guard zone.isMine, let e = privateEngine else { return }
        e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone.zoneID))])
    }

    func deleteZone(_ zone: ZoneRef) {
        guard zone.isMine, let e = privateEngine else { return }
        e.state.add(pendingDatabaseChanges: [.deleteZone(zone.zoneID)])
        metadata.removeZone(zone.zoneID)
    }

    /// Leaves a zone someone else shared with me. Deleting a zone in the shared database removes
    /// me as a participant; the owner's data is untouched.
    func leaveZone(_ zone: ZoneRef) {
        guard !zone.isMine, let e = sharedEngine else { return }
        e.state.add(pendingDatabaseChanges: [.deleteZone(zone.zoneID)])
        metadata.removeZone(zone.zoneID)
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
            saveState(e.stateSerialization, scope: scope)

        case .accountChange(let e):
            handleAccountChange(e)

        case .fetchedDatabaseChanges(let e):
            var changes: [RemoteChange] = []
            var baseZoneLost = false
            for d in e.deletions {
                metadata.removeZone(d.zoneID)
                let zone = ZoneRef(d.zoneID)
                if zone.isMine && (zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private) {
                    // My own base zone vanished (e.g. "Delete iCloud data" on another device).
                    // This device still has everything: recreate and re-upload.
                    baseZoneLost = true
                    continue
                }
                changes.append(.zoneDeleted(zone))
            }
            store.apply(changes)
            if baseZoneLost {
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: ZoneRef.me.zoneID)),
                    .saveZone(CKRecordZone(zoneID: ZoneRef.privateZone.zoneID))
                ])
                uploadEverythingMine()
            }

        case .fetchedRecordZoneChanges(let e):
            var changes: [RemoteChange] = []
            for m in e.modifications {
                let record = m.record
                metadata.update(record)
                if let decoded = RecordCoder.decode(record) {
                    changes.append(.upsert(decoded, zone: ZoneRef(record.recordID.zoneID)))
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
                if zone.isMine {
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
            store.resetForAccountChange(keepOnboarding: false)
            metadata.removeAll()
            deleteEngineStates()
            privateEngine = nil
            sharedEngine = nil
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
