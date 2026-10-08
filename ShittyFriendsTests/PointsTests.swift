import XCTest
@testable import ShittyFriends

final class PointsTests: XCTestCase {
    func testEveryTapPaysWithNoSessionCap() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 1_000_000)
        var half = 0
        for i in 0..<500 {
            t = t.addingTimeInterval(0.2)
            let o = PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: half, state: &state, roll: 0.99)
            XCTAssertEqual(o.gainedHalfPoints, 2, "tap \(i + 1) still pays: sessions are uncapped")
            half += o.gainedHalfPoints
        }
        XCTAssertEqual(half, 1000)
    }

    func testTappingAgainAfterAPauseStillPays() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 0)
        var half = 0
        for i in 0..<10 {
            t = t.addingTimeInterval(0.2)
            half += PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: half, state: &state, roll: 0.99).gainedHalfPoints
        }
        t = t.addingTimeInterval(45)
        let resumed = PointsEngine.tap(at: t, sessionTapsBefore: 10, sessionHalfPointsBefore: half, state: &state, roll: 0.99)
        XCTAssertEqual(resumed.gainedHalfPoints, 2)
        XCTAssertEqual(resumed.combo, 1)
    }

    func testDeletingAPoopKeepsItsPointsButUndoDoesNot() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        for _ in 0..<20 { clock.advance(0.2); store.tapPoop() }
        store.finish()
        XCTAssertEqual(store.pointsBalance, 20)
        store.delete(e.id)
        XCTAssertNil(store.my.events[e.id])
        XCTAssertEqual(store.pointsBalance, 20, "cleaning up history never takes points away")
        XCTAssertEqual(store.profile.bankedHalfPoints, 40)

        clock.advance(60)
        let mistake = store.startTimed()
        for _ in 0..<5 { clock.advance(0.2); store.tapPoop() }
        XCTAssertEqual(store.my.events[mistake.id]?.halfPoints, 10)
        store.performUndo()
        XCTAssertNil(store.my.events[mistake.id])
        XCTAssertEqual(store.pointsBalance, 20, "an undone mis-tap is erased completely")
    }

    func testBankedPointsSurviveProfileSyncFromAnotherDevice() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        for _ in 0..<10 { clock.advance(0.2); store.tapPoop() }
        store.finish()
        store.delete(e.id)
        XCTAssertEqual(store.profile.bankedHalfPoints, 20)

        // A newer profile from a device (or older app version) that never saw the bank.
        clock.advance(10)
        var newer = store.profile
        newer.bankedHalfPoints = 0
        newer.handle = "renamed"
        newer.updatedAt = clock.now.addingTimeInterval(5)
        store.apply([.upsert(.profile(newer), zone: .me)])
        XCTAssertEqual(store.profile.handle, "renamed")
        XCTAssertEqual(store.profile.bankedHalfPoints, 20, "banked points only ever grow")

        // An older profile that carries a bigger bank made elsewhere still contributes it.
        var older = store.profile
        older.bankedHalfPoints = 60
        older.updatedAt = clock.now.addingTimeInterval(-1000)
        store.apply([.upsert(.profile(older), zone: .me)])
        XCTAssertEqual(store.profile.bankedHalfPoints, 60)
        XCTAssertEqual(store.pointsBalance, 30)
    }

    func testNewSessionStartsWithCleanTapFeedback() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        store.startTimed()
        for _ in 0..<60 { clock.advance(0.2); store.tapPoop() }
        XCTAssertEqual(store.lastTap?.combo, 60)
        store.finish()
        clock.advance(60)
        store.startTimed()
        XCTAssertNil(store.lastTap, "the previous session's combo must not show on a fresh session")
        clock.advance(0.2)
        let first = store.tapPoop()
        XCTAssertEqual(first?.gainedHalfPoints, 2)
        XCTAssertEqual(first?.combo, 1)
    }

    func testCriticalsAddTheirBonus() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 0)
        var half = 0
        for i in 0..<200 {
            t = t.addingTimeInterval(0.2)
            half += PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: half, state: &state, roll: 0.0).gainedHalfPoints
        }
        XCTAssertEqual(half, 200 * (PointRules.standard.tapRate + PointRules.standard.criticalBonus))
    }

    func testNoDailyCapBetweenSessions() {
        var firstState = TapState()
        var secondState = TapState()
        let t = Date()
        let first = PointsEngine.tap(at: t, sessionTapsBefore: 0, sessionHalfPointsBefore: 0, state: &firstState, roll: 0.99)
        let second = PointsEngine.tap(at: t.addingTimeInterval(1), sessionTapsBefore: 0, sessionHalfPointsBefore: 0, state: &secondState, roll: 0.99)
        XCTAssertEqual(first.gainedHalfPoints, 2)
        XCTAssertEqual(second.gainedHalfPoints, 2, "a later session can earn normally; there is no daily allowance to exhaust")
    }

    func testAutoClickerEarnsNothing() {
        var state = TapState()
        let t = Date(timeIntervalSince1970: 0)
        _ = PointsEngine.tap(at: t, sessionTapsBefore: 0, sessionHalfPointsBefore: 0, state: &state, roll: 0.99)
        let fast = PointsEngine.tap(at: t.addingTimeInterval(0.01), sessionTapsBefore: 1, sessionHalfPointsBefore: 2, state: &state, roll: 0.99)
        XCTAssertTrue(fast.rateLimited)
        XCTAssertEqual(fast.gainedHalfPoints, 0)
    }

    func testComboEscalates() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 0)
        var last: TapOutcome?
        for i in 0..<40 {
            t = t.addingTimeInterval(0.15)
            last = PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: 0, state: &state, roll: 0.99)
        }
        XCTAssertEqual(last?.combo, 40)
        XCTAssertEqual(last?.comboLevel, 5)
        t = t.addingTimeInterval(3)
        let reset = PointsEngine.tap(at: t, sessionTapsBefore: 40, sessionHalfPointsBefore: 0, state: &state, roll: 0.99)
        XCTAssertEqual(reset.combo, 1)
    }

    func testTapOnlyDuringLiveSessionAndBuying() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        XCTAssertNil(store.tapPoop(), "no points without a live session")
        _ = store.logInstant()
        XCTAssertNil(store.tapPoop(), "instant logs don't earn points")
        for _ in 0..<3 {
            store.startTimed()
            for _ in 0..<300 { clock.advance(0.2); store.tapPoop() }
            store.finish()
            clock.advance(1)
        }
        XCTAssertEqual(store.pointsBalance, 900)
        XCTAssertThrowsError(try store.purchase(.lava)) // 4,500
        try store.purchase(.glossy) // 800
        XCTAssertEqual(store.pointsBalance, 100)
        XCTAssertTrue(store.ownedCosmetics.contains(.glossy))
        XCTAssertThrowsError(try store.purchase(.glossy)) { XCTAssertEqual($0 as? Store.PurchaseError, .alreadyOwned) }
        store.equip(.glossy)
        XCTAssertEqual(store.profile.equippedCosmetic, .glossy)
        store.equip(.legendary)
        XCTAssertEqual(store.profile.equippedCosmetic, .glossy, "can't equip what you don't own")
    }

    func testCosmeticPricesArePacedForUncappedTapping() {
        XCTAssertEqual(CosmeticID.glossy.price, 800)
        XCTAssertEqual(CosmeticID.legendary.price, 100_000)
        let paid = CosmeticID.allCases.filter { $0 != .classic }.map(\.price)
        XCTAssertTrue(zip(paid, paid.dropFirst()).allSatisfy { $0 <= $1 })
        let shines = PinShineID.allCases.filter { $0 != .classicWhite }.map(\.price)
        XCTAssertTrue(zip(shines, shines.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(PinShineID.golden.price, 5_000)
    }

    func testPointsPersistOnEventSoBalanceIsConflictFree() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(1)
        store.tapPoop()
        XCTAssertEqual(store.my.events[e.id]?.halfPoints, 2)
        XCTAssertEqual(store.my.events[e.id]?.taps, 1)
    }

    func testPinShinePurchasesSpendSameBalanceAsPoopCosmetics() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        XCTAssertEqual(store.ownedPinShines, [.classicWhite])
        XCTAssertEqual(store.profile.equippedPinShine, .classicWhite)
        for _ in 0..<10 {
            store.startTimed()
            for _ in 0..<520 { clock.advance(0.2); store.tapPoop() }
            store.finish()
            clock.advance(1)
        }
        XCTAssertEqual(store.pointsBalance, 5_200)
        try store.purchasePinShine(.golden) // 5,000
        XCTAssertEqual(store.pointsBalance, 200)
        XCTAssertTrue(store.ownedPinShines.contains(.golden))
        XCTAssertThrowsError(try store.purchasePinShine(.golden)) {
            XCTAssertEqual($0 as? Store.PurchaseError, .alreadyOwned)
        }
        XCTAssertThrowsError(try store.purchase(.glossy)) // 800 > 200
        store.equipPinShine(.golden)
        XCTAssertEqual(store.profile.equippedPinShine, .golden)
        store.equipPinShine(.aurora)
        XCTAssertEqual(store.profile.equippedPinShine, .golden)
        let recovered = try JSONDecoder().decode(MyState.self, from: JSONEncoder().encode(store.my))
        XCTAssertNotNil(recovered.profile?.pinShines[.golden])
        XCTAssertEqual(recovered.profile?.equippedPinShine, .golden)
    }

    func testLegacyCloudProfileAndPersonRefDecodeWithoutShineKeys() throws {
        let old = UserProfile(handle: "old", avatar: AvatarSpec(), color: .lime)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "equippedPinShine")
        json.removeValue(forKey: "pinShines")
        let oldBytes = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(UserProfile.self, from: oldBytes)
        XCTAssertEqual(loaded.equippedPinShine, .classicWhite)
        XCTAssertTrue(loaded.pinShines.isEmpty)

        let person = PersonRef(id: "one", profile: loaded)
        var personJson = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(person)) as? [String: Any])
        personJson.removeValue(forKey: "pinShine")
        let legacy = try JSONSerialization.data(withJSONObject: personJson)
        XCTAssertEqual(try JSONDecoder().decode(PersonRef.self, from: legacy).pinShine, .classicWhite)
    }

}
