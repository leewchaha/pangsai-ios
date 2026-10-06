import XCTest
@testable import ShittyFriends

final class ExportAndMeshTests: XCTestCase {
    func testExportContainsAllFilesAndNoSecrets() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(300)
        store.finish()
        store.attachLocation(PoopLocation(latitude: 36.7, longitude: 137.2, placeName: "Home, sweet \"home\"", locality: "Toyama", country: "Japan", countryCode: "JP"), to: e.id)
        store.addManual(at: clock.now.addingTimeInterval(-7200), duration: nil, location: nil)
        let link = FriendLink(userID: "_sam", person: PersonRef(id: "_sam", handle: "sam", avatar: AvatarSpec(), color: .sky), status: .active, myInbox: "SECRET_INBOX", theirInbox: "SECRET_THEIRS", pairKey: "SECRET_PAIRKEY")
        store.upsertFriendLink(link)
        _ = store.currentInvite()

        let files = try ExportBuilder.files(store: store, now: clock.now)
        let names = Set(files.map { $0.name })
        for required in ["profile.json", "poop-history.json", "poop-history.csv", "locations.json", "achievements.json", "groups.json", "friendships.json", "poop-with-me-sessions.json", "README.txt"] {
            XCTAssertTrue(names.contains(required), required)
        }
        let all = files.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        XCTAssertFalse(all.contains("SECRET"), "export must not leak tokens or keys")
        XCTAssertFalse(all.contains(store.my.invites.values.first!.secret))

        let csv = String(decoding: files.first { $0.name == "poop-history.csv" }!.data, as: UTF8.self)
        XCTAssertTrue(csv.contains("\"Home, sweet \"\"home\"\"\""), "CSV escaping")
        XCTAssertEqual(csv.split(separator: "\n").count, 3)

        // Import round trip into a fresh store dedupes by id
        let history = files.first { $0.name == "poop-history.json" }!.data
        let parsed = try ExportBuilder.parseHistory(history)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(store.importHistory(parsed), 0)
        let (fresh, _) = TestEnv.store(clock: clock)
        XCTAssertEqual(fresh.importHistory(parsed), 2)
        XCTAssertEqual(fresh.my.events[e.id]?.location?.countryCode, "JP")
        XCTAssertEqual(fresh.my.events[e.id]?.duration ?? 0, 300, accuracy: 0.01)
    }

    func testZipStructure() throws {
        let entries = [
            ZipWriter.Entry(path: "ShittyFriends Export/a.txt", data: Data("hello".utf8), modified: Date(timeIntervalSince1970: 1_790_000_000)),
            ZipWriter.Entry(path: "ShittyFriends Export/b.json", data: Data("{}".utf8))
        ]
        let zip = ZipWriter().archive(entries)
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(zip.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertEqual(CRC32.checksum(Data("hello".utf8)), 0x3610a686)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sf-test-\(UUID().uuidString).zip")
        try zip.write(to: out)
        print("ZIP_WRITTEN:\(out.path)")
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = FilePersistence(directory: dir)
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        store.startTimed()
        let link = store.createGroupLocal(name: "Housemates", object: .rubberDuck, color: .mint)!
        try p.save(my: store.my)
        try p.save(cache: store.cache)
        let my = p.loadMy()
        let cache = p.loadCache()
        XCTAssertEqual(my, store.my)
        XCTAssertEqual(cache.zones[link.zone]?.group?.name, "Housemates")
        // Corrupt main file -> backup is used after a second save
        try p.save(my: store.my)
        try Data("nope".utf8).write(to: dir.appendingPathComponent("my.json"))
        XCTAssertEqual(p.loadMy().events.count, 1)
    }

    func testTolerantDecodingKeepsDataWhenFieldsMissing() throws {
        let json = #"{"onboarded": true, "events": [], "unknownFutureField": 42}"#
        let s = try JSONDecoder().decode(MyState.self, from: Data(json.utf8))
        XCTAssertTrue(s.onboarded)
        XCTAssertEqual(s.settings, AppSettings())
    }

    func testPoopMeshIsWellFormed() {
        for shape in [PoopShape.classic, PoopShape.softServe, PoopShape.classic.lowPoly] {
            let m = PoopMesh.make(shape)
            XCTAssertEqual(m.positions.count, m.normals.count)
            XCTAssertEqual(m.positions.count / 3 * 2, m.uvs.count)
            XCTAssertEqual(m.indices.count % 3, 0)
            XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.vertexCount })
            XCTAssertFalse(m.positions.contains { $0.isNaN || $0.isInfinite })
            XCTAssertFalse(m.normals.contains { $0.isNaN })
            let b = m.bounds
            XCTAssertEqual(b.min.1, 0, accuracy: 1e-4, "sits on the ground")
            XCTAssertGreaterThan(b.max.1, 0.5)
            XCTAssertLessThan(b.max.1, 1.4)
        }
    }

    func testPoopMeshNormalsPointOutward() {
        // On the outer silhouette, normals must point away from the vertical axis (correct winding).
        let m = PoopMesh.make(.classic)
        var outward = 0, inward = 0
        var i = 0
        while i + 2 < m.positions.count {
            let x = m.positions[i], z = m.positions[i + 2]
            let r = (x * x + z * z).squareRoot()
            if r > 0.6 {
                let dot = (x * m.normals[i] + z * m.normals[i + 2]) / r
                if dot > 0 { outward += 1 } else { inward += 1 }
            }
            i += 3
        }
        XCTAssertGreaterThan(outward, 50)
        XCTAssertGreaterThan(outward, inward * 10)
    }

    func testPadNormalsPointUp() {
        var pad = PoopMesh.pad(.classic)
        pad.recomputeNormals()
        // Second ring from the top (theta > 0): normals should point up.
        let segs = 28
        let idx = (2 * (segs + 1) + 5) * 3
        XCTAssertGreaterThan(pad.normals[idx + 1], 0.3)
    }

    /// Writes OBJ previews when SF_MESH_PREVIEW is set (used to tune the shape on Linux).
    func testWriteMeshPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["SF_MESH_PREVIEW"] else { return }
        for (name, shape) in [("classic", PoopShape.classic), ("softserve", PoopShape.softServe)] {
            let m = PoopMesh.make(shape)
            var obj = ""
            var i = 0
            while i + 2 < m.positions.count {
                obj += "v \(m.positions[i]) \(m.positions[i + 1]) \(m.positions[i + 2])\n"
                obj += "vn \(m.normals[i]) \(m.normals[i + 1]) \(m.normals[i + 2])\n"
                i += 3
            }
            var t = 0
            while t + 2 < m.indices.count {
                obj += "f \(m.indices[t] + 1)//\(m.indices[t] + 1) \(m.indices[t + 1] + 1)//\(m.indices[t + 1] + 1) \(m.indices[t + 2] + 1)//\(m.indices[t + 2] + 1)\n"
                t += 3
            }
            try obj.write(toFile: dir + "/\(name).obj", atomically: true, encoding: .utf8)
        }
    }
}
