//
//  DailyMetric.swift
//  WhoopStore
//
//  Field shape reconstructed directly from StrandAnalytics/AnalyticsEngine.swift's
//  own `DailyMetric(day:totalSleepMin:efficiency:...)` construction call -- every
//  field name, type, and optionality below is taken verbatim from that call site,
//  not guessed. See the scope note in WhoopProtocol/Samples.swift for what this
//  package does and doesn't cover (storage shape yes; the WHOOP5 BLE decode that
//  produces the values stored here, no).
//
//  NOT Sendable, per StrandAnalytics's own doc comment on
//  `AnalyticsEngine.DayResult` ("it embeds DailyMetric / CachedSleepSession from
//  WhoopStore, which are not Sendable").
//

import Foundation
import GRDB

/// One day's rolled-up recovery/strain/sleep/activity metrics.
/// Primary key: `day` ("yyyy-MM-dd", UTC -- matches AnalyticsEngine.dayString).
public final class DailyMetric: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "daily_metric"

    public var day: String
    public var totalSleepMin: Double?
    public var efficiency: Double?
    public var deepMin: Double?
    public var remMin: Double?
    public var lightMin: Double?
    public var disturbances: Int?
    public var restingHr: Int?
    public var avgHrv: Double?
    public var recovery: Double?
    public var strain: Double?
    public var exerciseCount: Int
    public var spo2Pct: Double?
    public var skinTempDevC: Double?
    public var respRateBpm: Double?
    public var steps: Int?
    public var activeKcalEst: Double?

    public init(day: String,
                totalSleepMin: Double? = nil,
                efficiency: Double? = nil,
                deepMin: Double? = nil,
                remMin: Double? = nil,
                lightMin: Double? = nil,
                disturbances: Int? = nil,
                restingHr: Int? = nil,
                avgHrv: Double? = nil,
                recovery: Double? = nil,
                strain: Double? = nil,
                exerciseCount: Int = 0,
                spo2Pct: Double? = nil,
                skinTempDevC: Double? = nil,
                respRateBpm: Double? = nil,
                steps: Int? = nil,
                activeKcalEst: Double? = nil) {
        self.day = day
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.disturbances = disturbances
        self.restingHr = restingHr
        self.avgHrv = avgHrv
        self.recovery = recovery
        self.strain = strain
        self.exerciseCount = exerciseCount
        self.spo2Pct = spo2Pct
        self.skinTempDevC = skinTempDevC
        self.respRateBpm = respRateBpm
        self.steps = steps
        self.activeKcalEst = activeKcalEst
    }
}

extension DailyMetric {
    /// Table definition for the migrator (see WhoopDatabase.swift).
    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("day", .text).notNull().primaryKey()
            t.column("totalSleepMin", .double)
            t.column("efficiency", .double)
            t.column("deepMin", .double)
            t.column("remMin", .double)
            t.column("lightMin", .double)
            t.column("disturbances", .integer)
            t.column("restingHr", .integer)
            t.column("avgHrv", .double)
            t.column("recovery", .double)
            t.column("strain", .double)
            t.column("exerciseCount", .integer).notNull().defaults(to: 0)
            t.column("spo2Pct", .double)
            t.column("skinTempDevC", .double)
            t.column("respRateBpm", .double)
            t.column("steps", .integer)
            t.column("activeKcalEst", .double)
        }
    }
}
