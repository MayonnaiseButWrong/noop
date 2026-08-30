//
//  CachedSleepSession.swift
//  WhoopStore
//
//  Field shape reconstructed directly from StrandAnalytics/AnalyticsEngine.swift's
//  own `CachedSleepSession(startTs:endTs:efficiency:restingHr:avgHrv:stagesJSON:)`
//  construction call. See the scope note in WhoopProtocol/Samples.swift.
//

import Foundation
import GRDB

/// Cache row for one detected sleep session, one per night (a night can have
/// more than one detected session -- AnalyticsEngine maps `matched.map { ... }`
/// so there's no uniqueness constraint on the id / day here beyond autoincrement).
public final class CachedSleepSession: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cached_sleep_session"

    public var id: Int64?
    public var startTs: Int
    public var endTs: Int
    public var efficiency: Double
    public var restingHr: Int?
    public var avgHrv: Double?
    /// JSON-encoded `[StageSegment]` (StrandAnalytics's own
    /// `AnalyticsEngine.encodeStages` produces this string verbatim via
    /// JSONEncoder -- this column just stores what it hands over).
    public var stagesJSON: String?

    public init(id: Int64? = nil, startTs: Int, endTs: Int, efficiency: Double,
                restingHr: Int?, avgHrv: Double?, stagesJSON: String?) {
        self.id = id
        self.startTs = startTs
        self.endTs = endTs
        self.efficiency = efficiency
        self.restingHr = restingHr
        self.avgHrv = avgHrv
        self.stagesJSON = stagesJSON
    }

    public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension CachedSleepSession {
    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startTs", .integer).notNull()
            t.column("endTs", .integer).notNull()
            t.column("efficiency", .double).notNull()
            t.column("restingHr", .integer)
            t.column("avgHrv", .double)
            t.column("stagesJSON", .text)
        }
    }
}
