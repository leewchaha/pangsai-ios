import Foundation

/// User-owned export. Contains the user's own data and what they can see of their social graph.
/// Never contains secrets (pair keys, invite secrets, inbox tokens).
public enum ExportBuilder {
    public static let folder = "ShittyFriends Export"
    public static let version = 1

    public struct ExportEvent: Codable, Hashable {
        public var id: UUID
        public var source: String
        public var startedAt: Date
        public var endedAt: Date?
        public var durationSeconds: Double?
        public var location: ExportLocation?
        public var poopWithMeSessionID: UUID?
        public var partyID: UUID?
        public var manuallyAdjusted: Bool
        public var sharedToGroups: Bool
        public var points: Double
        public var taps: Int
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct ExportLocation: Codable, Hashable {
        public var latitude: Double
        public var longitude: Double
        public var placeName: String?
        public var locality: String?
        public var country: String?
        public var countryCode: String?
        public var accuracy: Double?
        public var capturedAt: Date
    }

    struct Envelope<T: Codable>: Codable {
        var exportVersion: Int
        var exportedAt: Date
        var data: T
    }

    struct ExportProfile: Codable {
        var handle: String
        var color: String
        var avatar: AvatarSpec
        var equippedCosmetic: String
        var createdAt: Date
        var pointsBalance: Int
        var lifetimePoints: Int
    }

    struct ExportFriend: Codable {
        var userID: String?
        var handle: String?
        var status: String
        var notifications: String
        var since: Date
    }

    struct ExportGroup: Codable {
        var groupID: UUID
        var name: String
        var owner: Bool
        var joinedAt: Date
        var sharesEvents: Bool
        var sharesLocations: Bool
        var members: [String]
    }

    struct ExportLocationRow: Codable {
        var eventID: UUID
        var timestamp: Date
        var location: ExportLocation
    }

    struct ExportAchievement: Codable {
        var id: String
        var title: String
        var unlockedAt: Date
        var metadata: [String: String]
    }

    struct ExportCosmetic: Codable {
        var id: String
        var name: String
        var rarity: String
        var unlockedAt: Date
        var cost: Int
    }

    struct ExportSession: Codable {
        var sessionID: UUID
        var createdBy: String
        var groupID: UUID?
        var createdAt: Date
        var participants: [String]
    }

    static func location(_ l: PoopLocation) -> ExportLocation {
        ExportLocation(latitude: l.latitude, longitude: l.longitude, placeName: l.placeName, locality: l.locality, country: l.country, countryCode: l.countryCode, accuracy: l.accuracy, capturedAt: l.capturedAt)
    }

    static func poopLocation(_ l: ExportLocation) -> PoopLocation {
        PoopLocation(latitude: l.latitude, longitude: l.longitude, placeName: l.placeName, locality: l.locality, country: l.country, countryCode: l.countryCode, accuracy: l.accuracy, capturedAt: l.capturedAt)
    }

    public static func exportEvent(_ e: PoopEvent) -> ExportEvent {
        ExportEvent(id: e.id, source: e.source.rawValue, startedAt: e.startedAt, endedAt: e.endedAt, durationSeconds: e.duration, location: e.location.map(location), poopWithMeSessionID: e.pwmSessionID, partyID: e.partyID, manuallyAdjusted: e.manuallyAdjusted, sharedToGroups: e.sharedToGroups, points: e.points, taps: e.taps, createdAt: e.createdAt, updatedAt: e.updatedAt)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Files of the export, relative to the export folder.
    public static func files(store: Store, now: Date = Date()) throws -> [(name: String, data: Data)] {
        let enc = encoder()
        let my = store.my
        let events = my.events.values.sorted { $0.startedAt < $1.startedAt }
        func wrap<T: Codable>(_ v: T) throws -> Data { try enc.encode(Envelope(exportVersion: version, exportedAt: now, data: v)) }

        var out: [(String, Data)] = []
        let p = store.profile
        out.append(("profile.json", try wrap(ExportProfile(handle: p.handle, color: p.color.rawValue, avatar: p.avatar, equippedCosmetic: p.equippedCosmetic.rawValue, createdAt: p.createdAt, pointsBalance: store.pointsBalance, lifetimePoints: store.lifetimePoints))))
        out.append(("poop-history.json", try wrap(events.map(exportEvent))))
        out.append(("poop-history.csv", Data(csv(events).utf8)))
        out.append(("locations.json", try wrap(events.compactMap { e in e.location.map { ExportLocationRow(eventID: e.id, timestamp: e.startedAt, location: location($0)) } })))
        out.append(("achievements.json", try wrap(my.achievements.values.sorted { $0.unlockedAt < $1.unlockedAt }.map { ExportAchievement(id: $0.id.rawValue, title: $0.id.title, unlockedAt: $0.unlockedAt, metadata: $0.metadata) })))
        out.append(("cosmetics.json", try wrap(my.cosmetics.values.sorted { $0.unlockedAt < $1.unlockedAt }.map { ExportCosmetic(id: $0.id.rawValue, name: $0.id.displayName, rarity: $0.id.rarity.rawValue, unlockedAt: $0.unlockedAt, cost: $0.cost) })))
        out.append(("groups.json", try wrap(store.groupSummaries.map { g in
            ExportGroup(groupID: g.link.id, name: g.name, owner: g.link.isOwner, joinedAt: g.link.joinedAt, sharesEvents: g.link.shareEvents, sharesLocations: g.link.shareLocations, members: g.members.map { g.labels[$0.id] ?? "@" + $0.person.handle })
        })))
        out.append(("friendships.json", try wrap(my.friendLinks.values.sorted { $0.createdAt < $1.createdAt }.map {
            ExportFriend(userID: $0.userID, handle: $0.person?.handle, status: $0.status.rawValue, notifications: $0.notify.rawValue, since: $0.createdAt)
        })))
        var sessions: [UUID: ExportSession] = [:]
        for a in my.pwmArchive.values {
            sessions[a.sessionID] = ExportSession(sessionID: a.sessionID, createdBy: a.creatorID, groupID: a.groupID, createdAt: a.createdAt, participants: a.participants.map { "@" + $0.handle })
        }
        for v in store.liveSessions(now: now) where sessions[v.session.id] == nil {
            sessions[v.session.id] = ExportSession(sessionID: v.session.id, createdBy: v.session.creatorID, groupID: v.session.groupID, createdAt: v.session.createdAt, participants: v.participants.filter { $0.status == .joined || $0.status == .done }.map { "@" + $0.person.handle })
        }
        out.append(("poop-with-me-sessions.json", try wrap(sessions.values.sorted { $0.createdAt < $1.createdAt })))
        out.append(("README.txt", Data(readme(now: now, count: events.count).utf8)))
        return out
    }

    public static func zip(store: Store, now: Date = Date()) throws -> Data {
        let entries = try files(store: store, now: now).map { ZipWriter.Entry(path: "\(folder)/\($0.name)", data: $0.data, modified: now) }
        return ZipWriter().archive(entries)
    }

    static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func csv(_ events: [PoopEvent]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["id,source,started_at,ended_at,duration_seconds,latitude,longitude,place,locality,country,poop_with_me_session,party,added_later,manually_adjusted,points"]
        for e in events {
            let row: [String] = [
                e.id.uuidString,
                e.source.rawValue,
                iso.string(from: e.startedAt),
                e.endedAt.map { iso.string(from: $0) } ?? "",
                e.duration.map { String(Int($0)) } ?? "",
                e.location.map { String($0.latitude) } ?? "",
                e.location.map { String($0.longitude) } ?? "",
                csvField(e.location?.placeName ?? ""),
                csvField(e.location?.locality ?? ""),
                csvField(e.location?.country ?? ""),
                e.pwmSessionID?.uuidString ?? "",
                e.partyID?.uuidString ?? "",
                e.source == .manual ? "true" : "false",
                e.manuallyAdjusted ? "true" : "false",
                String(e.points)
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func readme(now: Date, count: Int) -> String {
        """
        ShittyFriends Export
        ====================

        Exported: \(ISO8601DateFormatter().string(from: now))
        Poops: \(count)

        This is your data. It came from this device and your own iCloud account —
        ShittyFriends does not run a server that stores your history.

        Files
        -----
        profile.json                 your handle, avatar, color, points
        poop-history.json            every poop (source: timed | instant | manual)
        poop-history.csv             the same history as a spreadsheet
        locations.json               poops that have a location attached
        achievements.json            unlocked achievements
        cosmetics.json               unlocked poop cosmetics
        groups.json                  groups you're in and their members (handles only)
        friendships.json             your shitty friends (handles only)
        poop-with-me-sessions.json   Poop With Me sessions you took part in

        Dates are ISO 8601 (UTC). poop-history.json can be imported back
        (YOU → Data → Import) — existing entries are matched by id and never duplicated.
        """
    }

    // MARK: - Import

    public enum ImportError: Error, Equatable { case unreadable, wrongVersion }

    /// Parses poop-history.json (wrapped or bare array).
    public static func parseHistory(_ data: Data) throws -> [PoopEvent] {
        let dec = decoder()
        let rows: [ExportEvent]
        if let env = try? dec.decode(Envelope<[ExportEvent]>.self, from: data) {
            guard env.exportVersion <= version else { throw ImportError.wrongVersion }
            rows = env.data
        } else if let bare = try? dec.decode([ExportEvent].self, from: data) {
            rows = bare
        } else {
            throw ImportError.unreadable
        }
        return rows.map { r in
            let source = PoopSource(rawValue: r.source) ?? .manual
            // Imported live sessions are closed so they don't create presence.
            var end = r.endedAt
            if source == .timed && end == nil { end = r.startedAt.addingTimeInterval(r.durationSeconds ?? 0) }
            // Points are never imported: the file is user-editable, and cosmetics aren't restored either.
            return PoopEvent(id: r.id, source: source, startedAt: r.startedAt, endedAt: end, location: r.location.map(poopLocation), pwmSessionID: r.poopWithMeSessionID, partyID: r.partyID, manuallyAdjusted: r.manuallyAdjusted, sharedToGroups: r.sharedToGroups, halfPoints: 0, taps: 0, createdAt: r.createdAt, updatedAt: r.updatedAt)
        }
    }
}

public extension Store {
    /// Merges imported history. Returns how many new events were added.
    @discardableResult
    func importHistory(_ events: [PoopEvent]) -> Int {
        var added = 0
        var effects: [Effect] = []
        for var e in events where my.events[e.id] == nil {
            e.halfPoints = 0
            e.taps = 0
            if e.isLive { e.endedAt = e.startedAt }
            put(e)
            // Not mirrored to groups: groups only see poops logged after joining (friends see all history).
            effects.append(.save(.event(e.id)))
            added += 1
        }
        emit(effects)
        if added > 0 { evaluateAchievements() }
        return added
    }
}
