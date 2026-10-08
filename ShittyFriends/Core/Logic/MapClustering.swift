import Foundation

public struct MapPoint: Hashable, Sendable, Identifiable {
    public var id: String
    public var ownerID: UserID
    public var latitude: Double
    public var longitude: Double
    public var label: String
    public var date: Date
    /// Recorded duration (timed / manual with an end); nil for instant logs and live sessions.
    public var duration: TimeInterval?
    /// A timer that is still running.
    public var isLive: Bool

    public init(id: String, ownerID: UserID, latitude: Double, longitude: Double, label: String, date: Date, duration: TimeInterval? = nil, isLive: Bool = false) {
        self.id = id
        self.ownerID = ownerID
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
        self.date = date
        self.duration = duration
        self.isLive = isLive
    }
}

public struct MapCluster: Hashable, Sendable, Identifiable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var points: [MapPoint]

    public var count: Int { points.count }

    /// Unique people in this cluster, newest poop first. This drives Home pin stacking.
    public var ownerIDsByRecency: [UserID] {
        var seen = Set<UserID>()
        return points.sorted { $0.date > $1.date }.compactMap { point in
            seen.insert(point.ownerID).inserted ? point.ownerID : nil
        }
    }

    /// Owner with the most points in the cluster (ties: most recent).
    public var dominantOwner: UserID {
        var counts: [UserID: (n: Int, latest: Date)] = [:]
        for p in points {
            let c = counts[p.ownerID] ?? (0, .distantPast)
            counts[p.ownerID] = (c.n + 1, max(c.latest, p.date))
        }
        return counts.max { a, b in a.value.n != b.value.n ? a.value.n < b.value.n : a.value.latest < b.value.latest }?.key ?? ""
    }
    public var latest: MapPoint? { points.max(by: { $0.date < $1.date }) }
    /// Every poop at this spot, newest first (the Home detail list).
    public var pointsByRecency: [MapPoint] { points.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id } }
}

public enum MapClustering {
    /// Map-first Home pins: combine only genuinely co-located poop positions (full history).
    /// The marker coordinate is ALWAYS an actual event coordinate (the newest one),
    /// not the center of a screen-sized grid cell or an averaged position between users.
    /// This also keeps locations stable while the camera zoom changes.
    public static func atRecordedLocations(_ points: [MapPoint], withinMeters: Double = 25) -> [MapCluster] {
        let ordered = points.sorted { a, b in
            a.date == b.date ? a.id < b.id : a.date > b.date
        }
        var groups: [[MapPoint]] = []
        for point in ordered {
            if let idx = groups.firstIndex(where: { group in
                guard let anchor = group.first else { return false }
                return GeoMath.distance(lat1: anchor.latitude, lon1: anchor.longitude,
                                        lat2: point.latitude, lon2: point.longitude) <= withinMeters
            }) {
                groups[idx].append(point)
            } else {
                groups.append([point])
            }
        }
        return groups.compactMap { group in
            guard let newest = group.first else { return nil }
            return MapCluster(id: "recorded-" + newest.id,
                              latitude: newest.latitude, longitude: newest.longitude, points: group)
        }
    }

    /// Grid clustering in screen-ish space: the visible span is divided into `cellsAcross` columns.
    public static func cluster(_ points: [MapPoint], latitudeDelta: Double, longitudeDelta: Double, cellsAcross: Double = 7) -> [MapCluster] {
        let cellLon = max(longitudeDelta / cellsAcross, 0.00005)
        let cellLat = max(latitudeDelta / (cellsAcross * 1.6), 0.00005)
        var buckets: [String: [MapPoint]] = [:]
        for p in points {
            let x = Int((p.longitude / cellLon).rounded(.down))
            let y = Int((p.latitude / cellLat).rounded(.down))
            buckets["\(x):\(y)", default: []].append(p)
        }
        return buckets.map { key, pts in
            let lat = pts.reduce(0) { $0 + $1.latitude } / Double(pts.count)
            let lon = pts.reduce(0) { $0 + $1.longitude } / Double(pts.count)
            let sorted = pts.sorted { $0.date > $1.date }
            return MapCluster(id: key + ":" + (sorted.first?.id ?? ""), latitude: lat, longitude: lon, points: sorted)
        }.sorted { $0.id < $1.id }
    }

    /// Fun travel stats for the map header.
    public static func farthestFromHome(_ locations: [PoopLocation]) -> (location: PoopLocation, meters: Double)? {
        guard let home = PlaceClustering.places(locations).first else { return nil }
        var best: (PoopLocation, Double)?
        for l in locations {
            let d = GeoMath.distance(lat1: home.latitude, lon1: home.longitude, lat2: l.latitude, lon2: l.longitude)
            if d > (best?.1 ?? -1) { best = (l, d) }
        }
        return best.map { (location: $0.0, meters: $0.1) }
    }
}
