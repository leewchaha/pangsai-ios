import Foundation

public struct MapPoint: Hashable, Sendable, Identifiable {
    public var id: String
    public var ownerID: UserID
    public var latitude: Double
    public var longitude: Double
    public var label: String
    public var date: Date

    public init(id: String, ownerID: UserID, latitude: Double, longitude: Double, label: String, date: Date) {
        self.id = id
        self.ownerID = ownerID
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
        self.date = date
    }
}

public struct MapCluster: Hashable, Sendable, Identifiable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var points: [MapPoint]

    public var count: Int { points.count }
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
}

public enum MapClustering {
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
