import CloudKit
import Foundation

/// Maps store entities <-> CKRecords.
///
/// Every record carries its full model as JSON in a single `json` BYTES field plus `updatedAt`.
/// That keeps the CloudKit schema tiny and stable: adding model fields never needs a schema deploy.
enum RecordCoder {
    static let jsonKey = "json"
    static let updatedAtKey = "updatedAt"
    static let versionKey = "schemaVersion"
    static let currentVersion = 1

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: - Encode

    /// Builds the record to upload for `ref` from current store state. Returns nil if the entity no longer exists.
    @MainActor
    static func record(for ref: RecordRef, store: Store, base: CKRecord?) -> CKRecord? {
        guard let (data, updatedAt) = payload(for: ref, store: store) else { return nil }
        let record = base ?? CKRecord(recordType: ref.recordType, recordID: ref.recordID)
        record[jsonKey] = data as CKRecordValue
        record[updatedAtKey] = updatedAt as CKRecordValue
        record[versionKey] = currentVersion as CKRecordValue
        return record
    }

    @MainActor
    static func payload(for ref: RecordRef, store: Store) -> (Data, Date)? {
        let my = store.my
        let cache = store.cache
        func enc<T: Encodable>(_ v: T?, _ date: Date) -> (Data, Date)? {
            guard let v = v, let data = try? encoder.encode(v) else { return nil }
            return (data, date)
        }
        switch ref {
        case .profile:
            return enc(my.profile, my.profile?.updatedAt ?? Date())
        case .event(let id):
            let e = my.events[id]
            return enc(e, e?.updatedAt ?? Date())
        case .achievement(let id):
            let a = my.achievements[id]
            return enc(a, a?.unlockedAt ?? Date())
        case .cosmetic(let id):
            let c = my.cosmetics[id]
            return enc(c, c?.unlockedAt ?? Date())
        case .settings:
            return enc(my.settings, my.settings.updatedAt)
        case .friendLink(let id):
            let l = my.friendLinks[id]
            return enc(l, l?.updatedAt ?? Date())
        case .groupLink(let id):
            let l = my.groupLinks[id]
            return enc(l, l?.updatedAt ?? Date())
        case .invite(let token):
            let i = my.invites[token]
            return enc(i, i?.createdAt ?? Date())
        case .spaceLink(let zone):
            let s = my.spaceLinks[zone]
            return enc(s, s?.createdAt ?? Date())
        case .groupInfo(let zone):
            let g = cache.zones[zone]?.group
            return enc(g, g?.updatedAt ?? Date())
        case .member(let zone, let uid):
            let m = cache.zones[zone]?.members[uid]
            return enc(m, m?.updatedAt ?? Date())
        case .groupEvent(let zone, let id):
            let e = cache.zones[zone]?.events[id]
            return enc(e, e?.updatedAt ?? Date())
        case .pwmSession(let zone, let id):
            let s = cache.zones[zone]?.sessions[id]
            return enc(s, s?.updatedAt ?? Date())
        case .participant(let zone, let sid, let uid):
            let p = cache.zones[zone]?.participants[sid]?[uid]
            return enc(p, p?.updatedAt ?? Date())
        case .reaction(let zone, let id):
            let r = cache.zones[zone]?.reactions[id]
            return enc(r, r?.at ?? Date())
        case .party(let zone, let id):
            let p = cache.zones[zone]?.parties[id]
            return enc(p, p?.updatedAt ?? Date())
        case .rsvp(let zone, let pid, let uid):
            let r = cache.zones[zone]?.rsvps[pid]?[uid]
            return enc(r, r?.updatedAt ?? Date())
        }
    }

    // MARK: - Decode

    static func decode(_ record: CKRecord) -> RemoteRecord? {
        guard let data = record[jsonKey] as? Data else { return nil }
        func dec<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(type, from: data) }
        switch record.recordType {
        case RecordTypes.profile: return dec(UserProfile.self).map { .profile($0) }
        case RecordTypes.event: return dec(PoopEvent.self).map { .event($0) }
        case RecordTypes.achievement: return dec(AchievementUnlock.self).map { .achievement($0) }
        case RecordTypes.cosmetic: return dec(CosmeticUnlock.self).map { .cosmetic($0) }
        case RecordTypes.settings: return dec(AppSettings.self).map { .settings($0) }
        case RecordTypes.friendLink: return dec(FriendLink.self).map { .friendLink($0) }
        case RecordTypes.groupLink: return dec(GroupLink.self).map { .groupLink($0) }
        case RecordTypes.invite: return dec(OutgoingInvite.self).map { .invite($0) }
        case RecordTypes.spaceLink: return dec(SpaceLink.self).map { .spaceLink($0) }
        case RecordTypes.groupInfo: return dec(GroupInfo.self).map { .groupInfo($0) }
        case RecordTypes.member: return dec(GroupMember.self).map { .member($0) }
        case RecordTypes.groupEvent: return dec(GroupEvent.self).map { .groupEvent($0) }
        case RecordTypes.pwmSession: return dec(PWMSession.self).map { .pwmSession($0) }
        case RecordTypes.participant: return dec(PWMParticipant.self).map { .participant($0) }
        case RecordTypes.reaction: return dec(Reaction.self).map { .reaction($0) }
        case RecordTypes.party: return dec(Party.self).map { .party($0) }
        case RecordTypes.rsvp: return dec(PartyRSVP.self).map { .rsvp($0) }
        default: return nil
        }
    }

    static func updatedAt(_ record: CKRecord) -> Date? {
        record[updatedAtKey] as? Date
    }

    // MARK: - System fields

    static func archiveSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func unarchiveSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}

/// Last-known server system fields (change tags) per record, so saves don't conflict needlessly.
@MainActor
final class RecordMetadataStore {
    private var fields: [String: Data] = [:]
    private let url: URL
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    init(directory: URL) {
        url = directory.appendingPathComponent("record-metadata.plist")
        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            fields = dict
        }
    }

    static func key(_ id: CKRecord.ID) -> String {
        "\(id.zoneID.ownerName)|\(id.zoneID.zoneName)|\(id.recordName)"
    }

    func baseRecord(for id: CKRecord.ID) -> CKRecord? {
        fields[Self.key(id)].flatMap { RecordCoder.unarchiveSystemFields($0) }
    }

    func update(_ record: CKRecord) {
        fields[Self.key(record.recordID)] = RecordCoder.archiveSystemFields(record)
        scheduleSave()
    }

    func remove(_ id: CKRecord.ID) {
        fields[Self.key(id)] = nil
        scheduleSave()
    }

    func removeZone(_ zoneID: CKRecordZone.ID) {
        let prefix = "\(zoneID.ownerName)|\(zoneID.zoneName)|"
        fields = fields.filter { !$0.key.hasPrefix(prefix) }
        scheduleSave()
    }

    func removeAll() {
        fields = [:]
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        if let data = try? PropertyListEncoder().encode(fields) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
