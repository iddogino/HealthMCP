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
    var phase: String?
    var completedTypes: Int?
    var totalTypes: Int?
    var maxReadMS: Double?
    var maxIndexMS: Double?
    var maxChunkMS: Double?
    var availability: SyncAvailability?
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
struct IndexedSample: Sendable {
    let uuid: String, hkType: String, series: String, period: String
    let start: Date, end: Date
}
struct DirtyChunk: Identifiable, Hashable, Sendable { let series: String, period: String; var id: String { series + "/" + period } }
struct ChunkCoverage: Codable, Sendable { let series: String, period: String, first: String, last: String }
struct UploadedSummary: Sendable { let series: String, count: Int, first: String, last: String }

// Only UUIDs, period boundaries, anchors, and operational history are persisted.
// Health values are queried per chunk and encrypted in memory.
actor SyncStore {
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private init(url: URL? = nil) throws {
        let directory = url?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HealthMCP", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = directory; try excluded.setResourceValues(values)
        let path = url ?? directory.appendingPathComponent("sync.sqlite")
        guard sqlite3_open(path.path, &database) == SQLITE_OK else { throw HealthMCPError.message("Could not open the sync journal.") }
    }
    private func configure() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS anchors (type TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS samples (uuid TEXT NOT NULL, hk_type TEXT NOT NULL, series TEXT NOT NULL, period TEXT NOT NULL, t0 REAL NOT NULL, t1 REAL NOT NULL, PRIMARY KEY(uuid,series))")
        try execute("CREATE INDEX IF NOT EXISTS sample_period ON samples(series,period)")
        try execute("CREATE INDEX IF NOT EXISTS sample_type ON samples(hk_type,uuid)")
        try execute("CREATE INDEX IF NOT EXISTS sample_intervals ON samples(series,t0,t1)")
        try execute("CREATE TABLE IF NOT EXISTS dirty (series TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS derived (series TEXT NOT NULL, period TEXT NOT NULL, count INTEGER NOT NULL, first_day TEXT NOT NULL, last_day TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, started REAL NOT NULL, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS uploaded (series TEXT NOT NULL, period TEXT NOT NULL, count INTEGER NOT NULL, first_day TEXT NOT NULL, last_day TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS catalog_pending (series TEXT PRIMARY KEY)")
        try execute("CREATE TABLE IF NOT EXISTS chunk_visits (series TEXT NOT NULL, period TEXT NOT NULL, run_id TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS coverage_pending (series TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS recent_pending (series TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(series,period))")
        try execute("CREATE TABLE IF NOT EXISTS recent_cursors (type TEXT PRIMARY KEY, value BLOB NOT NULL, complete INTEGER NOT NULL)")
        if try rows("SELECT 1 FROM sync_metadata WHERE key='incremental-v1'").isEmpty {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("ALTER TABLE dirty ADD COLUMN priority INTEGER NOT NULL DEFAULT 0")
                // Only clean periods have been acknowledged by the old uploader. Keep its anchors and unfinished work.
                try execute("INSERT OR IGNORE INTO uploaded SELECT s.series,s.period,COUNT(*),strftime('%Y-%m-%d',MIN(s.t0),'unixepoch'),strftime('%Y-%m-%d',MAX(s.t1),'unixepoch') FROM samples s WHERE NOT EXISTS (SELECT 1 FROM dirty d WHERE d.series=s.series AND d.period=s.period) GROUP BY s.series,s.period")
                try execute("INSERT OR IGNORE INTO uploaded SELECT series,period,count,first_day,last_day FROM derived")
                try execute("INSERT INTO sync_metadata(key,value) VALUES('incremental-v1','1')")
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        if try rows("SELECT 1 FROM sync_metadata WHERE key='catalog-publication-v1'").isEmpty {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT OR IGNORE INTO catalog_pending SELECT DISTINCT series FROM uploaded")
                try execute("INSERT INTO sync_metadata(key,value) VALUES('catalog-publication-v1','1')")
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        if try rows("SELECT 1 FROM sync_metadata WHERE key='chunk-coverage-v1'").isEmpty {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT OR IGNORE INTO coverage_pending SELECT series,period FROM uploaded WHERE series NOT IN ('profile','check')")
                try execute("INSERT INTO sync_metadata(key,value) VALUES('chunk-coverage-v1','1')")
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }
    static func open(url: URL? = nil) async throws -> SyncStore {
        let store = try await Task.detached(priority: .utility) { try SyncStore(url: url) }.value
        try await store.configure()
        return store
    }
    deinit { for statement in statements.values { sqlite3_finalize(statement) }; sqlite3_close(database) }
    private func statement(_ sql: String, _ args: [Any]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if let cached = statements[sql] { statement = cached; sqlite3_reset(cached); sqlite3_clear_bindings(cached) }
        else {
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else { throw HealthMCPError.message("Could not read the sync journal.") }
            statements[sql] = prepared
        }
        guard let statement else { throw HealthMCPError.message("Could not prepare the sync journal.") }
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
        let stmt = try statement(sql, args); defer { sqlite3_reset(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw HealthMCPError.message("Could not save sync progress. Please check available storage.") }
    }
    func rows(_ sql: String, _ args: [Any] = []) throws -> [[String: Any]] {
        let stmt = try statement(sql, args); defer { sqlite3_reset(stmt) }
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
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, i) { row[key] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))) }
                    else { row[key] = Data() }
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
            var dirty = Set<DirtyChunk>()
            var relatedStart: Double?, relatedEnd: Double?
            func changed(_ row: [String: Any]) {
                dirty.formUnion(dirtyFromRow(row))
                guard let series = row["series"] as? String, Self.workoutInputs.contains(series) else { return }
                let start = Self.number(row["t0"]), end = Self.number(row["t1"])
                relatedStart = min(relatedStart ?? start, start); relatedEnd = max(relatedEnd ?? end, end)
            }
            for id in deleted {
                for old in try rows("SELECT series,period,t0,t1 FROM samples WHERE hk_type=? AND uuid=?", [type, id.uuidString.lowercased()]) { changed(old) }
                try execute("DELETE FROM samples WHERE hk_type=? AND uuid=?", [type, id.uuidString.lowercased()])
            }
            for sample in samples {
                for old in try rows("SELECT series,period,t0,t1 FROM samples WHERE uuid=? AND series=?", [sample.uuid, sample.series]) { changed(old) }
                try execute("INSERT OR REPLACE INTO samples(uuid,hk_type,series,period,t0,t1) VALUES(?,?,?,?,?,?)", [sample.uuid, type, sample.series, sample.period, sample.start.timeIntervalSince1970, sample.end.timeIntervalSince1970])
                changed(["series": sample.series, "period": sample.period, "t0": sample.start.timeIntervalSince1970, "t1": sample.end.timeIntervalSince1970])
            }
            // Associated heart rate and routes can arrive after the workout itself.
            // Coalesce a page's interval into one indexed lookup, including deletions.
            if let start = relatedStart, let end = relatedEnd {
                for row in try rows("SELECT period FROM samples WHERE series='workouts' AND t0<=? AND t1>=?", [end, start]) {
                    if let period = row["period"] as? String { dirty.insert(DirtyChunk(series: "workouts", period: period)) }
                }
            }
            for chunk in dirty { try markDirty(chunk.series, chunk.period) }
            if let anchor { try execute("INSERT OR REPLACE INTO anchors(type,value) VALUES(?,?)", [type, try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private static let summaryInputs: Set<String> = ["steps", "active_energy", "exercise_minutes", "resting_heart_rate", "hrv_sdnn", "blood_glucose", "blood_oxygen", "sleep", "workouts"]
    private static let ringInputs: Set<String> = ["active_energy", "exercise_minutes", "stand_minutes", "stand_hour", "workouts"]
    private static let workoutInputs: Set<String> = ["heart_rate", "active_energy", "distance_walking_running", "distance_cycling", "distance_swimming", "_workout_routes"]
    private static func number(_ value: Any?) -> Double { (value as? Double) ?? Double(value as? Int ?? 0) }
    private func dirtyFromRow(_ row: [String: Any]) -> Set<DirtyChunk> {
        guard let series = row["series"] as? String, let period = row["period"] as? String else { return [] }
        var dirty: Set<DirtyChunk> = series.hasPrefix("_") ? [] : [DirtyChunk(series: series, period: period)]
        guard Self.summaryInputs.contains(series) || Self.ringInputs.contains(series) else { return dirty }
        let start = Date(timeIntervalSince1970: Self.number(row["t0"]))
        let end = Date(timeIntervalSince1970: Self.number(row["t1"]))
        var month = HealthDates.calendar.date(from: HealthDates.calendar.dateComponents([.year, .month], from: start))!
        repeat {
            let period = HealthDates.month(month)
            if Self.summaryInputs.contains(series) { dirty.insert(DirtyChunk(series: "daily_summary", period: period)) }
            if Self.ringInputs.contains(series) { dirty.insert(DirtyChunk(series: "activity_rings", period: period)) }
            month = HealthDates.calendar.date(byAdding: .month, value: 1, to: month)!
        } while month <= end
        return dirty
    }
    func markDirty(_ series: String, _ period: String, priority: Int = 0) throws { try execute("INSERT INTO dirty(series,period,priority) VALUES(?,?,?) ON CONFLICT(series,period) DO UPDATE SET priority=MAX(priority,excluded.priority)", [series, period, priority]) }
    func clearDirty(_ chunk: DirtyChunk) throws { try execute("DELETE FROM dirty WHERE series=? AND period=?", [chunk.series, chunk.period]) }
    func dirtyChunks() throws -> [DirtyChunk] { try rows("SELECT series,period FROM dirty ORDER BY CASE WHEN series='daily_summary' THEN 1 ELSE 0 END,series,period").compactMap { row in guard let series = row["series"] as? String, let period = row["period"] as? String else { return nil }; return DirtyChunk(series: series, period: period) } }
    func nextDirty(limit: Int, excluding: Set<String> = [], notUploadedInRun: String? = nil) throws -> [DirtyChunk] {
        try rows("SELECT d.series,d.period FROM dirty d LEFT JOIN chunk_visits v ON v.series=d.series AND v.period=d.period WHERE COALESCE(v.run_id,'')!=? ORDER BY d.priority DESC,d.period DESC,d.series LIMIT ?", [notUploadedInRun ?? "-", limit + excluding.count])
            .compactMap { row -> DirtyChunk? in guard let series = row["series"] as? String, let period = row["period"] as? String else { return nil }; return DirtyChunk(series: series, period: period) }
            .filter { !excluding.contains($0.id) }.prefix(limit).map { $0 }
    }
    func dirtyCount() throws -> Int { try rows("SELECT COUNT(*) AS count FROM dirty").first?["count"] as? Int ?? 0 }
    func seedRecent(_ chunks: [DirtyChunk], day: String) throws {
        guard try rows("SELECT value FROM sync_metadata WHERE key='recent-seed'").first?["value"] as? String != day else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for chunk in chunks { try markDirty(chunk.series, chunk.period, priority: chunk.series == "daily_summary" ? 200 : 100) }
            try execute("INSERT OR REPLACE INTO sync_metadata(key,value) VALUES('recent-seed',?)", [day])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func recordUpload(_ chunk: DirtyChunk, count: Int, first: String, last: String, runID: String? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if count > 0 { try execute("INSERT OR REPLACE INTO uploaded(series,period,count,first_day,last_day) VALUES(?,?,?,?,?)", [chunk.series, chunk.period, count, first, last]) }
            else { try execute("DELETE FROM uploaded WHERE series=? AND period=?", [chunk.series, chunk.period]) }
            try execute("INSERT OR IGNORE INTO catalog_pending(series) VALUES(?)", [chunk.series])
            if let runID { try execute("INSERT OR REPLACE INTO chunk_visits(series,period,run_id) VALUES(?,?,?)", [chunk.series, chunk.period, runID]) }
            try execute("DELETE FROM coverage_pending WHERE series=? AND period=?", [chunk.series, chunk.period])
            try execute("DELETE FROM recent_pending WHERE series=? AND period=?", [chunk.series, chunk.period])
            try clearDirty(chunk)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func pendingCoverage(limit: Int = 200) throws -> [ChunkCoverage] {
        try rows("SELECT u.* FROM uploaded u JOIN coverage_pending p ON p.series=u.series AND p.period=u.period ORDER BY u.series,u.period LIMIT ?", [limit]).compactMap { row in
            guard let series = row["series"] as? String, let period = row["period"] as? String, let first = row["first_day"] as? String, let last = row["last_day"] as? String else { return nil }
            return ChunkCoverage(series: series, period: period, first: first, last: last)
        }
    }
    func acknowledgeCoverage(_ coverage: [ChunkCoverage], missing: [DirtyChunk] = []) throws {
        try transaction {
            for chunk in missing { try markDirty(chunk.series, chunk.period, priority: 50) }
            for item in coverage { try execute("DELETE FROM coverage_pending WHERE series=? AND period=?", [item.series, item.period]) }
        }
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    func uploadedSummary(_ series: String) throws -> UploadedSummary {
        let row = try rows("SELECT COALESCE(SUM(count),0) AS count,MIN(first_day) AS first,MAX(last_day) AS last FROM uploaded WHERE series=?", [series]).first ?? [:]
        return UploadedSummary(series: series, count: row["count"] as? Int ?? 0, first: row["first"] as? String ?? HealthDates.day(Date()), last: row["last"] as? String ?? HealthDates.day(Date()))
    }
    func pendingCatalog() throws -> [String] { try rows("SELECT series FROM catalog_pending ORDER BY series").compactMap { $0["series"] as? String } }
    func acknowledgeCatalog(_ series: String) throws { try execute("DELETE FROM catalog_pending WHERE series=?", [series]) }
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
        try transaction {
        let types = Set(try rows("SELECT DISTINCT hk_type FROM samples WHERE series=?", [series]).compactMap { $0["hk_type"] as? String } + SeriesDefinition.all.filter { $0.id == series }.compactMap { $0.sampleType?.identifier })
        for type in types { try execute("DELETE FROM anchors WHERE type=?", [type]) }
        for table in ["samples", "dirty", "derived", "uploaded", "catalog_pending", "chunk_visits", "coverage_pending"] { try execute("DELETE FROM \(table) WHERE series=?", [series]) }
        try execute("DELETE FROM sync_metadata WHERE key='recent-seed'")
        try clearAvailability()
        }
    }
    func resetIndex() throws { try transaction { for table in ["samples", "anchors", "dirty", "derived", "uploaded", "catalog_pending", "chunk_visits", "coverage_pending"] { try execute("DELETE FROM \(table)") }; try execute("DELETE FROM sync_metadata WHERE key='recent-seed'"); try clearAvailability() } }
}
