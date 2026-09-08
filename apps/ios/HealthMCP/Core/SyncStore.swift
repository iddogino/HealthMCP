import Foundation
import HealthKit
import SQLite3

struct SyncRun: Codable, Identifiable {
    var id = UUID().uuidString
    var trigger: String
    var startedAt = Date()
    var finishedAt: Date?
    var status = "running"
    var stage = "Preparing your encrypted cache"
    var progress = 0.0
    var totalChunks = 0
    var uploadedChunks = 0
    var uploadedBytes = 0
    var sampleCount = 0
    var errors: [String] = []
    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    mutating func pauseForProtectedData() {
        status = "paused"
        stage = "Unlock your iPhone and open Health MCP to resume. Your progress is saved."
    }
}
enum SyncInterruption: Error {
    case healthDataLocked
    static func isHealthDataLocked(_ error: Error) -> Bool {
        if case .healthDataLocked = error as? SyncInterruption { return true }
        let error = error as NSError
        return error.domain == HKErrorDomain && error.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }
}
struct IndexedSample {
    let uuid: String, hkType: String, series: String, period: String
    let start: Date, end: Date
}
struct DirtyChunk: Identifiable { let series: String, period: String; var id: String { series + "/" + period } }

// Only UUIDs, period boundaries, anchors, and operational history are persisted.
// Health values are queried per chunk and encrypted in memory.
@MainActor final class SyncStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL? = nil) throws {
        let directory = url?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HealthMCP", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = directory; try excluded.setResourceValues(values)
        let path = url ?? directory.appendingPathComponent("sync.sqlite")
        guard sqlite3_open(path.path, &database) == SQLITE_OK else { throw HealthMCPError.message("Could not open the sync journal.") }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS anchors (type TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS samples (uuid TEXT NOT NULL, hk_type TEXT NOT NULL, series TEXT NOT NULL, period TEXT NOT NULL, t0 REAL NOT NULL, t1 REAL NOT NULL, PRIMARY KEY(uuid,series))")
        try execute("CREATE INDEX IF NOT EXISTS sample_period ON samples(series,period)")
        try execute("CREATE INDEX IF NOT EXISTS sample_type ON samples(hk_type,uuid)")
        try execute("CREATE TABLE IF NOT EXISTS dirty (series TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS derived (series TEXT NOT NULL, period TEXT NOT NULL, count INTEGER NOT NULL, first_day TEXT NOT NULL, last_day TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, started REAL NOT NULL, value BLOB NOT NULL)")
    }
    deinit { sqlite3_close(database) }
    private func statement(_ sql: String, _ args: [Any]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw HealthMCPError.message("Could not read the sync journal.") }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
    func execute(_ sql: String, _ args: [Any] = []) throws {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw HealthMCPError.message("Could not save sync progress. Please check available storage.") }
    }
    func rows(_ sql: String, _ args: [Any] = []) throws -> [[String: Any]] {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[key] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_INTEGER: row[key] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
                case SQLITE_BLOB: row[key] = Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
                default: break
                }
            }
            rows.append(row)
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw HealthMCPError.message("Could not finish reading the sync journal.") }
        return rows
    }
    func anchor(for type: String) throws -> HKQueryAnchor? {
        guard let data = try rows("SELECT value FROM anchors WHERE type=?", [type]).first?["value"] as? Data else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    func applyPage(type: String, samples: [IndexedSample], deleted: [UUID], anchor: HKQueryAnchor?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for id in deleted {
                for old in try rows("SELECT series,period,t0,t1 FROM samples WHERE hk_type=? AND uuid=?", [type, id.uuidString.lowercased()]) { try dirtyFromRow(old) }
                try execute("DELETE FROM samples WHERE hk_type=? AND uuid=?", [type, id.uuidString.lowercased()])
            }
            for sample in samples {
                for old in try rows("SELECT series,period,t0,t1 FROM samples WHERE uuid=? AND series=?", [sample.uuid, sample.series]) { try dirtyFromRow(old) }
                try execute("INSERT OR REPLACE INTO samples(uuid,hk_type,series,period,t0,t1) VALUES(?,?,?,?,?,?)", [sample.uuid, type, sample.series, sample.period, sample.start.timeIntervalSince1970, sample.end.timeIntervalSince1970])
                try markDirty(sample.series, sample.period)
                try markDirty("daily_summary", HealthDates.month(sample.start))
                try markDirty("activity_rings", HealthDates.month(sample.start))
                if HealthDates.month(sample.start) != HealthDates.month(sample.end) {
                    try markDirty("daily_summary", HealthDates.month(sample.end))
                    try markDirty("activity_rings", HealthDates.month(sample.end))
                }
            }
            if let anchor { try execute("INSERT OR REPLACE INTO anchors(type,value) VALUES(?,?)", [type, try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func dirtyFromRow(_ row: [String: Any]) throws {
        guard let series = row["series"] as? String, let period = row["period"] as? String else { return }
        try markDirty(series, period)
        let start = (row["t0"] as? Double) ?? Double(row["t0"] as? Int ?? 0)
        let end = (row["t1"] as? Double) ?? Double(row["t1"] as? Int ?? Int(start))
        for month in Set([HealthDates.month(Date(timeIntervalSince1970: start)), HealthDates.month(Date(timeIntervalSince1970: end))]) {
            try markDirty("daily_summary", month)
            try markDirty("activity_rings", month)
        }
    }
    func markDirty(_ series: String, _ period: String) throws { try execute("INSERT OR IGNORE INTO dirty(series,period) VALUES(?,?)", [series, period]) }
    func clearDirty(_ chunk: DirtyChunk) throws { try execute("DELETE FROM dirty WHERE series=? AND period=?", [chunk.series, chunk.period]) }
    func dirtyChunks() throws -> [DirtyChunk] { try rows("SELECT series,period FROM dirty ORDER BY CASE WHEN series='daily_summary' THEN 1 ELSE 0 END,series,period").compactMap { row in guard let series = row["series"] as? String, let period = row["period"] as? String else { return nil }; return DirtyChunk(series: series, period: period) } }
    func totalSamples() throws -> Int { try rows("SELECT COUNT(*) AS count FROM samples").first?["count"] as? Int ?? 0 }
    func summary(_ series: String) throws -> (Int, Date, Date)? {
        guard let row = try rows("SELECT COUNT(*) AS count,MIN(t0) AS first,MAX(t1) AS last FROM samples WHERE series=?", [series]).first, let count = row["count"] as? Int, count > 0 else { return nil }
        func number(_ key: String) -> Double { (row[key] as? Double) ?? Double(row[key] as? Int ?? 0) }
        return (count, Date(timeIntervalSince1970: number("first")), Date(timeIntervalSince1970: number("last")))
    }
    func save(_ run: SyncRun) throws {
        try execute("INSERT OR REPLACE INTO history(id,started,value) VALUES(?,?,?)", [run.id, run.startedAt.timeIntervalSince1970, try JSONEncoder().encode(run)])
        try execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY started DESC LIMIT 100)")
    }
    func history() throws -> [SyncRun] { try rows("SELECT value FROM history ORDER BY started DESC").compactMap { ($0["value"] as? Data).flatMap { try? JSONDecoder().decode(SyncRun.self, from: $0) } } }
    func recordDerived(series: String, period: String, count: Int, first: String, last: String) throws { try execute("INSERT OR REPLACE INTO derived(series,period,count,first_day,last_day) VALUES(?,?,?,?,?)", [series, period, count, first, last]) }
    func derivedSummary(_ series: String) throws -> (Int, String, String)? {
        guard let row = try rows("SELECT SUM(count) AS count,MIN(first_day) AS first,MAX(last_day) AS last FROM derived WHERE series=? AND count>0", [series]).first, let count = row["count"] as? Int, let first = row["first"] as? String, let last = row["last"] as? String else { return nil }
        return (count, first, last)
    }
    func clearSeries(_ series: String) throws {
        let types = Set(try rows("SELECT DISTINCT hk_type FROM samples WHERE series=?", [series]).compactMap { $0["hk_type"] as? String } + SeriesDefinition.all.filter { $0.id == series }.compactMap { $0.sampleType?.identifier })
        for type in types { try execute("DELETE FROM anchors WHERE type=?", [type]) }
        for table in ["samples", "dirty", "derived"] { try execute("DELETE FROM \(table) WHERE series=?", [series]) }
    }
    func resetIndex() throws { for table in ["samples", "anchors", "dirty", "derived"] { try execute("DELETE FROM \(table)") } }
}
