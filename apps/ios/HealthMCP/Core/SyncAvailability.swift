import Foundation
import HealthKit

/// A confirmed, published range. `refreshedAt` is when its recent HealthKit
/// scan began, not the time an arbitrary historical chunk was uploaded.
struct SyncAvailability: Codable, Equatable, Sendable {
    var since: Date
    var refreshedAt: Date
    var scope: String
    var historyComplete: Bool
    var hasSamples: Bool

    static func scope(for definitions: [SeriesDefinition]) -> String {
        definitions.map { "\($0.id):\($0.hkName):\($0.chunk)" }.sorted().joined(separator: "|")
    }

    var sinceLabel: String {
        // Chunk boundaries use UTC. Do not move the displayed day back in
        // time when the phone is west of UTC.
        since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: HealthDates.calendar, timeZone: HealthDates.calendar.timeZone))
    }

    func freshnessLabel(at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(refreshedAt) / 60))
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) \(minutes == 1 ? "min" : "mins") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) \(hours == 1 ? "hour" : "hours") ago" }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

struct RecentSyncScan: Codable, Sendable {
    let since: Date
    let through: Date
    let scope: String
}

extension SyncStore {
    private func availabilityValue<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let value = try rows("SELECT value FROM sync_metadata WHERE key=?", [key]).first?["value"] as? String else { return nil }
        return try JSONDecoder().decode(type, from: Data(value.utf8))
    }
    private func saveAvailabilityValue<T: Encodable>(_ value: T, key: String) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try execute("INSERT OR REPLACE INTO sync_metadata(key,value) VALUES(?,?)", [key, json])
    }
    func availability(for definitions: [SeriesDefinition]) throws -> SyncAvailability? {
        let value = try availabilityValue("availability-v1", as: SyncAvailability.self)
        return value?.scope == SyncAvailability.scope(for: definitions) ? value : nil
    }

    /// The pending list includes empty periods too: no samples is a completed
    /// query, whereas no uploaded row alone cannot prove that we checked it.
    /// A paused scan resumes its fixed window and cursors, without redoing
    /// hundreds of acknowledged recent chunks on every app open.
    func beginRecentScan(definitions: [SeriesDefinition], now: Date) throws -> RecentSyncScan? {
        let scope = SyncAvailability.scope(for: definitions)
        if let scan = try availabilityValue("recent-scan-v1", as: RecentSyncScan.self), scan.scope == scope { return scan }
        // After the backfill, ordinary anchored deltas can confirm freshness
        // without rereading a whole week on every background refresh.
        if try availability(for: definitions)?.historyComplete == true { return nil }
        let scan = RecentSyncScan(since: BackfillPlan.recentStart(now: now), through: now, scope: scope)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM recent_pending")
            try execute("DELETE FROM recent_cursors")
            for chunk in BackfillPlan.recentChunks(definitions: definitions, now: now) { try queueRecent(chunk) }
            // Re-query previously uploaded records as well, so deletions that
            // happened before this scan are reflected in the confirmed range.
            for series in Set(definitions.filter { $0.chunk == "record" && $0.kind != .route }.map(\.id)) {
                for row in try rows("SELECT period FROM uploaded WHERE series=? AND last_day>=? AND first_day<=?", [series, HealthDates.day(scan.since), HealthDates.day(now)]) {
                    if let period = row["period"] as? String { try queueRecent(DirtyChunk(series: series, period: period)) }
                }
            }
            try saveAvailabilityValue(scan, key: "recent-scan-v1")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return scan
    }
    private func queueRecent(_ chunk: DirtyChunk) throws {
        try execute("INSERT OR IGNORE INTO recent_pending(series,period) VALUES(?,?)", [chunk.series, chunk.period])
        try markDirty(chunk.series, chunk.period, priority: 300)
    }
    func recentCursor(for type: String) throws -> (anchor: HKQueryAnchor?, complete: Bool) {
        guard let row = try rows("SELECT value,complete FROM recent_cursors WHERE type=?", [type]).first else { return (nil, false) }
        let data = row["value"] as? Data ?? Data()
        let anchor = data.isEmpty ? nil : try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        return (anchor, row["complete"] as? Int == 1)
    }
    func stageRecentRecords(type: String, page: HealthPage) throws {
        var removed = [DirtyChunk]()
        for id in page.deleted {
            for row in try rows("SELECT series,period FROM samples WHERE hk_type=? AND uuid=?", [type, id.uuidString.lowercased()]) {
                if let series = row["series"] as? String, let period = row["period"] as? String { removed.append(DirtyChunk(series: series, period: period)) }
            }
        }
        // Queue before changing the index so a deletion still has durable work
        // if the process exits between index commit and cursor commit.
        try execute("BEGIN IMMEDIATE")
        do {
            for sample in page.samples { try queueRecent(DirtyChunk(series: sample.series, period: sample.period)) }
            for chunk in removed { try queueRecent(chunk) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        // Never save a predicate-specific cursor as the full-history anchor.
        try applyPage(type: type, samples: page.samples, deleted: page.deleted, anchor: nil)
        let data = try page.anchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) } ?? Data()
        try execute("INSERT OR REPLACE INTO recent_cursors(type,value,complete) VALUES(?,?,?)", [type, data, page.hasMore ? 0 : 1])
    }
    func nextRecentChunks(limit: Int, excluding: Set<String>) throws -> [DirtyChunk] {
        try rows("SELECT series,period FROM recent_pending ORDER BY period DESC,series LIMIT ?", [limit + excluding.count])
            .compactMap { row -> DirtyChunk? in
                guard let series = row["series"] as? String, let period = row["period"] as? String else { return nil }
                return DirtyChunk(series: series, period: period)
            }.filter { !excluding.contains($0.id) }.prefix(limit).map { $0 }
    }
    func confirmRecentScan(definitions: [SeriesDefinition]) throws -> SyncAvailability? {
        guard let scan = try availabilityValue("recent-scan-v1", as: RecentSyncScan.self), scan.scope == SyncAvailability.scope(for: definitions) else { return try availability(for: definitions) }
        for definition in definitions where definition.chunk == "record" && definition.kind != .route {
            if let type = definition.sampleType?.identifier, try !recentCursor(for: type).complete { return try availability(for: definitions) }
        }
        guard try rows("SELECT 1 FROM recent_pending LIMIT 1").isEmpty, try pendingCatalog().isEmpty else { return try availability(for: definitions) }
        let previous = try availability(for: definitions)
        let value = SyncAvailability(since: min(previous?.since ?? scan.since, scan.since), refreshedAt: scan.through, scope: scan.scope, historyComplete: false, hasSamples: try hasPublishedSamples())
        try execute("BEGIN IMMEDIATE")
        do {
            try saveAvailabilityValue(value, key: "availability-v1")
            try execute("INSERT OR REPLACE INTO sync_metadata(key,value) VALUES('recent-seed',?)", [HealthDates.day(scan.through)])
            try execute("DELETE FROM sync_metadata WHERE key='recent-scan-v1'")
            try execute("DELETE FROM recent_cursors")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return value
    }
    /// Only call once EVERY full-history query reached its anchor. At that
    /// point the newest pending bucket bounds the gaps in the older range.
    /// Uploads before enumeration finishes cannot establish that frontier.
    func extendAvailability(definitions: [SeriesDefinition], refreshedAt: Date? = nil) throws -> SyncAvailability? {
        guard var value = try availability(for: definitions), try pendingCatalog().isEmpty else { return try availability(for: definitions) }
        // Compare bucket ENDS: a pending September monthly bucket blocks
        // September 30 even if a daily September 9 key sorts after it. A
        // multi-day workout also blocks through the end of its interval.
        let boundary = try rows("""
            SELECT MAX(MAX(
                CASE WHEN length(d.period)=7 THEN date(d.period||'-01','+1 month') ELSE date(substr(d.period,1,10),'+1 day') END,
                COALESCE(date(u.last_day,'+1 day'),''),
                CASE WHEN instr(d.period,'/')>0 THEN COALESCE((SELECT date(MAX(t1),'unixepoch','+1 day') FROM samples s WHERE s.series=d.series AND s.period=d.period),'') ELSE '' END
            )) AS boundary FROM dirty d LEFT JOIN uploaded u ON u.series=d.series AND u.period=d.period
            """).first?["boundary"] as? String
        if let boundary {
            value.since = min(value.since, try HealthDates.bounds(boundary).0)
        } else {
            if let first = try rows("SELECT MIN(first_day) AS first FROM uploaded WHERE series NOT IN ('profile','check')").first?["first"] as? String {
                value.since = min(value.since, try HealthDates.bounds(first).0)
            }
            if let refreshedAt { value.refreshedAt = refreshedAt; value.historyComplete = true }
        }
        value.hasSamples = try hasPublishedSamples()
        try saveAvailabilityValue(value, key: "availability-v1")
        return value
    }
    private func hasPublishedSamples() throws -> Bool {
        try !rows("SELECT 1 FROM uploaded WHERE series NOT IN ('profile','check','daily_summary','activity_rings') AND count>0 LIMIT 1").isEmpty
    }
    func clearAvailability() throws {
        try execute("DELETE FROM recent_pending")
        try execute("DELETE FROM recent_cursors")
        try execute("DELETE FROM sync_metadata WHERE key IN ('availability-v1','recent-scan-v1')")
    }
}
