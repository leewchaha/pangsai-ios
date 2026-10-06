import XCTest
@testable import ShittyFriends

final class PointsTests: XCTestCase {
    func testRateTiersAndSessionCap() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 1_000_000)
        var half = 0
        var daily = 0
        for i in 0..<200 {
            t = t.addingTimeInterval(0.2)
            let o = PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: half, dailyHalfPointsBefore: daily, state: &state, roll: 0.99)
            half += o.gainedHalfPoints
            daily += o.gainedHalfPoints
            if i < 30 { XCTAssertEqual(o.gainedHalfPoints, 2) }
            else if i < 60 { XCTAssertEqual(o.gainedHalfPoints, 1) }
            else { XCTAssertEqual(o.gainedHalfPoints, 0) }
        }
        // 30*1 + 30*0.5 = 45 points, under the 50 cap
        XCTAssertEqual(half, 90)
    }

    func testCriticalsRespectSessionCap() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 0)
        var half = 0
        for i in 0..<200 {
            t = t.addingTimeInterval(0.2)
            half += PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: half, dailyHalfPointsBefore: half, state: &state, roll: 0.0).gainedHalfPoints
        }
        XCTAssertEqual(half, PointRules.standard.sessionCap)
    }

    func testDailyCapIsFrequencyNeutral() {
        // Second session in the same day can earn at most the remaining daily room.
        var state = TapState()
        let o = PointsEngine.tap(at: Date(), sessionTapsBefore: 0, sessionHalfPointsBefore: 0, dailyHalfPointsBefore: 119, state: &state, roll: 0.99)
        XCTAssertEqual(o.gainedHalfPoints, 1)
        XCTAssertTrue(o.dailyCapped)
        let o2 = PointsEngine.tap(at: Date().addingTimeInterval(1), sessionTapsBefore: 1, sessionHalfPointsBefore: 1, dailyHalfPointsBefore: 120, state: &state, roll: 0.99)
        XCTAssertEqual(o2.gainedHalfPoints, 0)
    }

    func testAutoClickerEarnsNothing() {
        var state = TapState()
        let t = Date(timeIntervalSince1970: 0)
        _ = PointsEngine.tap(at: t, sessionTapsBefore: 0, sessionHalfPointsBefore: 0, dailyHalfPointsBefore: 0, state: &state, roll: 0.99)
        let fast = PointsEngine.tap(at: t.addingTimeInterval(0.01), sessionTapsBefore: 1, sessionHalfPointsBefore: 2, dailyHalfPointsBefore: 2, state: &state, roll: 0.99)
        XCTAssertTrue(fast.rateLimited)
        XCTAssertEqual(fast.gainedHalfPoints, 0)
    }

    func testComboEscalates() {
        var state = TapState()
        var t = Date(timeIntervalSince1970: 0)
        var last: TapOutcome?
        for i in 0..<40 {
            t = t.addingTimeInterval(0.15)
            last = PointsEngine.tap(at: t, sessionTapsBefore: i, sessionHalfPointsBefore: 0, dailyHalfPointsBefore: 0, state: &state, roll: 0.99)
        }
        XCTAssertEqual(last?.combo, 40)
        XCTAssertEqual(last?.comboLevel, 5)
        t = t.addingTimeInterval(3)
        let reset = PointsEngine.tap(at: t, sessionTapsBefore: 40, sessionHalfPointsBefore: 0, dailyHalfPointsBefore: 0, state: &state, roll: 0.99)
        XCTAssertEqual(reset.combo, 1)
    }

    func testTapOnlyDuringLiveSessionAndBuying() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        XCTAssertNil(store.tapPoop(), "no points without a live session")
        _ = store.logInstant()
        XCTAssertNil(store.tapPoop(), "instant logs don't earn points")
        store.startTimed()
        for _ in 0..<60 { clock.advance(0.2); store.tapPoop() }
        store.finish()
        XCTAssertEqual(store.pointsBalance, 45)
        XCTAssertThrowsError(try store.purchase(.lava)) // 120
        try store.purchase(.glossy) // 25
        XCTAssertEqual(store.pointsBalance, 20)
        XCTAssertTrue(store.ownedCosmetics.contains(.glossy))
        XCTAssertThrowsError(try store.purchase(.glossy)) { XCTAssertEqual($0 as? Store.PurchaseError, .alreadyOwned) }
        store.equip(.glossy)
        XCTAssertEqual(store.profile.equippedCosmetic, .glossy)
        store.equip(.legendary)
        XCTAssertEqual(store.profile.equippedCosmetic, .glossy, "can't equip what you don't own")
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
}
