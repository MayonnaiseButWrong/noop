//
//  WhoopDatabase.swift
//  WhoopStore
//
//  Minimal GRDB database wrapper: schema migration + basic read/write for
//  DailyMetric and CachedSleepSession. This is standard GRDB boilerplate,
//  not anything WHOOP-specific -- the WHOOP-specific part is just the two
//  table shapes defined alongside their record types.
//

import Foundation
import GRDB

public final class WhoopDatabase {
    public let dbQueue: DatabaseQueue

    /// Opens (creating if needed) a database at the given file URL and runs
    /// migrations. Pass nil to get an in-memory database (useful for tests/
    /// previews).
    public init(path: URL?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path.path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_tables") { db in
            try DailyMetric.createTable(db)
            try CachedSleepSession.createTable(db)
        }
        return migrator
    }

    // MARK: - DailyMetric

    public func upsert(_ metric: DailyMetric) throws {
        try dbQueue.write { db in
            try metric.save(db)
        }
    }

    public func dailyMetric(forDay day: String) throws -> DailyMetric? {
        try dbQueue.read { db in
            try DailyMetric.filter(Column("day") == day).fetchOne(db)
        }
    }

    public func dailyMetrics(from startDay: String, to endDay: String) throws -> [DailyMetric] {
        try dbQueue.read { db in
            try DailyMetric
                .filter(Column("day") >= startDay && Column("day") <= endDay)
                .order(Column("day"))
                .fetchAll(db)
        }
    }

    public func allDailyMetrics() throws -> [DailyMetric] {
        try dbQueue.read { db in
            try DailyMetric.order(Column("day")).fetchAll(db)
        }
    }

    // MARK: - CachedSleepSession

    @discardableResult
    public func insert(_ session: CachedSleepSession) throws -> CachedSleepSession {
        try dbQueue.write { db in
            try session.insert(db)
            return session
        }
    }

    public func sleepSessions(overlappingStart start: Int, end: Int) throws -> [CachedSleepSession] {
        try dbQueue.read { db in
            try CachedSleepSession
                .filter(Column("startTs") <= end && Column("endTs") >= start)
                .order(Column("startTs"))
                .fetchAll(db)
        }
    }

    public func deleteAllSleepSessions() throws {
        try dbQueue.write { db in
            _ = try CachedSleepSession.deleteAll(db)
        }
    }
}
