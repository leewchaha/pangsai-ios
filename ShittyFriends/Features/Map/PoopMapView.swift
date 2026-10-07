import MapKit
import SwiftUI

/// Where everyone pooped. Only per-poop locations — never live tracking.
struct PoopMapView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    @State private var latDelta: Double = 40
    @State private var lonDelta: Double = 40
    @State private var filter: Filter = .everyone
    @State private var selected: MapCluster?

    enum Filter: Hashable {
        case everyone, me, friends, group(ZoneRef)
    }

    private var store: Store { model.store }

    private var points: [MapPoint] {
        let groups = Set(store.groupSummaries.map { $0.link.zone })
        switch filter {
        case .everyone: return store.mapPoints(includeMine: true, friendIDs: nil, groupZones: groups)
        case .me: return store.mapPoints(includeMine: true, friendIDs: [], groupZones: [])
        case .friends: return store.mapPoints(includeMine: false, friendIDs: nil, groupZones: [])
        case .group(let z): return store.mapPoints(includeMine: false, friendIDs: [], groupZones: [z])
        }
    }

    var body: some View {
        let pts = points
        let clusters = MapClustering.cluster(pts, latitudeDelta: latDelta, longitudeDelta: lonDelta)
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(clusters) { c in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), anchor: .bottom) {
                        PoopPin(cluster: c, person: store.person(for: c.dominantOwner), selected: selected?.id == c.id)
                            .onTapGesture {
                                Haptics.tick()
                                withAnimation(Motion.bouncy) { selected = c }
                            }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                latDelta = ctx.region.span.latitudeDelta
                lonDelta = ctx.region.span.longitudeDelta
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                header(pts)
                filters
            }
            .padding(.top, 4)
            .gutter()
        }
        .overlay(alignment: .bottom) {
            if let c = selected {
                ClusterCard(cluster: c) { withAnimation(Motion.snappy) { selected = nil } }
                    .gutter()
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if pts.isEmpty {
                EmptyState(emoji: "🗺️", title: "NO POOP PINS YET", message: "Tap 📍 during a session to attach where it happened. Your friends' shared spots show up here too.")
                    .sticker(Palette.card)
                    .gutter()
                    .padding(.bottom, 110)
            }
        }
    }

    private func header(_ pts: [MapPoint]) -> some View {
        let locations = pts.map { PoopLocation(latitude: $0.latitude, longitude: $0.longitude, placeName: $0.label) }
        let places = PlaceClustering.places(locations).count
        let mine = store.my.events.values.compactMap(\.location)
        let cities = Set(mine.compactMap { $0.locality?.lowercased() }).count
        let countries = Set(mine.compactMap { ($0.countryCode ?? $0.country)?.uppercased() }).count
        let far = MapClustering.farthestFromHome(mine)
        return HStack(spacing: 8) {
            mapStat("\(places)", "PLACES")
            mapStat("\(cities)", "MY CITIES")
            mapStat("\(countries)", "COUNTRIES")
            mapStat(far.map { $0.meters >= 1000 ? "\(Int($0.meters / 1000))km" : "\(Int($0.meters))m" } ?? "—", "FARTHEST")
        }
    }

    private func mapStat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.digits(18)).lineLimit(1).minimumScaleFactor(0.5)
            Text(l).font(.heading(8))
        }
        .foregroundStyle(Palette.inkFixed)
        .frame(maxWidth: .infinity, minHeight: 50)
        .sticker(.white, radius: 14, shadow: 3, stroke: 2)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("EVERYONE", .everyone)
                chip("ME", .me)
                chip("FRIENDS", .friends)
                ForEach(store.groupSummaries) { g in chip(g.name.uppercased(), .group(g.link.zone)) }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ text: String, _ f: Filter) -> some View {
        Button {
            withAnimation(Motion.snappy) {
                filter = f
                selected = nil
            }
        } label: {
            Chip(text: text, fill: .white, ink: Palette.inkFixed, selected: filter == f)
        }
        .buttonStyle(PressableStyle())
    }
}

struct PoopPin: View {
    var cluster: MapCluster
    var person: PersonRef?
    var selected: Bool
    @State private var drop = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Object3DImage(subject: .poop(person?.cosmetic ?? .classic), size: selected ? 64 : 50)
                if let p = person {
                    AvatarView(person: p, size: 26)
                        .offset(x: 10, y: -6)
                }
                if cluster.count > 1 {
                    Text("\(cluster.count)")
                        .font(.heading(11))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Palette.tomato))
                        .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1.5))
                        .offset(x: -36, y: -4)
                }
            }
            Text(label)
                .font(.heading(10))
                .foregroundStyle(Palette.inkFixed)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(person?.color.color ?? Palette.sun))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1.5))
        }
        .scaleEffect(drop ? 1 : 0.2, anchor: .bottom)
        .onAppear { withAnimation(Motion.bouncy) { drop = true } }
        .animation(Motion.bouncy, value: selected)
    }

    private var label: String {
        let who = person.map { "@" + $0.handle } ?? ""
        let place = cluster.latest?.label ?? ""
        return [who, place].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ClusterCard: View {
    @Environment(AppModel.self) private var model
    var cluster: MapCluster
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("📍 " + (cluster.latest?.label ?? "Somewhere")).font(.heading(16)).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 14, weight: .black)) }
                    .accessibilityLabel("Close")
            }
            Text("\(cluster.count) poop\(cluster.count == 1 ? "" : "s") here").font(.ui(13, .semibold)).foregroundStyle(Palette.muted)
            ForEach(cluster.points.prefix(5)) { p in
                HStack {
                    HandleText(handle: model.store.person(for: p.ownerID)?.handle ?? "someone", size: 13)
                    Spacer()
                    Text(p.date.formatted(date: .abbreviated, time: .shortened)).font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(16)
        .sticker(Palette.card)
    }
}
