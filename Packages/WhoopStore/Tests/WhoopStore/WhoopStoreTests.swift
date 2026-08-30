import XCTest
@testable import WhoopStore

final class WhoopStoreTests: XCTestCase {
    func testDailyMetricRoundTrip() throws {
        let db = try WhoopDatabase(path: nil)
        let metric = DailyMetric(day: "2026-08-28", totalSleepMin: 420, efficiency: 0.91,
                                  deepMin: 80, remMin: 95, lightMin: 245, disturbances: 3,
                                  restingHr: 52, avgHrv: 68.4, recovery: 71, strain: 12.3,
                                  exerciseCount: 1, respRateBpm: 14.2, steps: 8421,
                                  activeKcalEst: 2100)
        try db.upsert(metric)

        let fetched = try db.dailyMetric(forDay: "2026-08-28")
        XCTAssertEqual(fetched?.day, "2026-08-28")
        XCTAssertEqual(fetched?.recovery, 71)
        XCTAssertEqual(fetched?.steps, 8421)
    }

    func testCachedSleepSessionInsertAndQuery() throws {
        let db = try WhoopDatabase(path: nil)
        let session = CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.88,
                                          restingHr: 50, avgHrv: 70.0, stagesJSON: "[]")
        let inserted = try db.insert(session)
        XCTAssertNotNil(inserted.id)

        let overlapping = try db.sleepSessions(overlappingStart: 2000, end: 3000)
        XCTAssertEqual(overlapping.count, 1)
        XCTAssertEqual(overlapping.first?.startTs, 1000)
    }
}
