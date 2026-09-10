import XCTest
import HealthKit
@testable import HealthMCP

final class SyncAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_955_200) // Sep 9, 2026 at noon UTC
    private var steps: SeriesDefinition { SeriesDefinition.quantities.first { $0.id == "steps" }! }
    private var mass: SeriesDefinition { SeriesDefinition.quantities.first { $0.id == "body_mass" }! }
    private var workouts: SeriesDefinition { SeriesDefinition.all.first { $0.id == "workouts" }! }
    private func date(_ day: String) throws -> Date { try HealthDates.bounds(day).0 }
    private func instant(_ value: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: value)) }
    private func database() async throws -> (SyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite")
        return (try await SyncStore.open(url: url), url)
    }
    private func publishCatalog(_ store: SyncStore) async throws {
        for series in try await store.pendingCatalog() { try await store.acknowledgeCatalog(series) }
    }
    private func acknowledge(_ chunk: DirtyChunk, in store: SyncStore, count: Int = 1) async throws {
        let day = HealthDates.day(try HealthDates.bounds(chunk.period).0)
        try await store.recordUpload(chunk, count: count, first: day, last: day)
    }
    private func confirm(_ store: SyncStore, definitions: [SeriesDefinition]) async throws -> SyncAvailability {
        _ = try await store.beginRecentScan(definitions: definitions, now: now)
        for chunk in try await store.nextRecentChunks(limit: 1000, excluding: []) { try await acknowledge(chunk, in: store) }
        try await publishCatalog(store)
        let confirmed = try await store.confirmRecentScan(definitions: definitions)
        return try XCTUnwrap(confirmed)
    }

    func testRecentPlanCoversSevenCompleteDatesAcrossMonthBoundary() throws {
        let plan = BackfillPlan.recentChunks(definitions: [steps, mass, mass], now: try date("2026-09-02") + 43200)
        XCTAssertEqual(plan.filter { $0.series == "steps" }.count, 7)
        for series in ["body_mass", "daily_summary", "activity_rings"] {
            XCTAssertTrue(plan.contains(DirtyChunk(series: series, period: "2026-08")))
            XCTAssertTrue(plan.contains(DirtyChunk(series: series, period: "2026-09")))
        }
        XCTAssertEqual(HealthDates.day(BackfillPlan.recentStart(now: try date("2026-09-02"))), "2026-08-27")
    }

    func testUTCTomorrowDisplaysAsTheCurrentLocalDayWithoutChangingStoredDates() throws {
        let observed = try instant("2026-09-10T01:22:34Z") // Sep 9, 6:22 PM in California
        let range = try XCTUnwrap(PublishedDataRange.fromCatalog([
            ["series": "steps", "total_samples": 10, "first_day": "2026-09-10", "last_day": "2026-09-10", "last_synced_at": observed.timeIntervalSince1970]
        ], definitions: [steps], observedAt: observed))
        let label = range.rangeLabel(at: observed, in: TimeZone(identifier: "America/Los_Angeles")!, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label, "Sep 9, 2026")
        XCTAssertEqual(HealthDates.day(range.first), "2026-09-10")
        XCTAssertEqual(HealthDates.day(range.last), "2026-09-10", "Presentation must not rewrite UTC cache/MCP boundaries")
        XCTAssertEqual(range.displayBounds(at: observed).last, observed)
    }

    func testHistoricalUTCDayUsesItsWholeIntervalAndHandlesEasternTimeZones() throws {
        let range = PublishedDataRange(first: try date("2026-09-09"), last: try date("2026-09-09"), updatedAt: try instant("2026-09-12T00:00:00Z"), scope: "fixture")
        let observed = try instant("2026-09-12T00:00:00Z"), locale = Locale(identifier: "en_US")
        XCTAssertEqual(range.rangeLabel(at: observed, in: TimeZone(identifier: "America/Los_Angeles")!, locale: locale), "Sep 8, 2026 – Sep 9, 2026", "Formatting the last UTC midnight directly would incorrectly end on Sep 8")
        XCTAssertEqual(range.rangeLabel(at: observed, in: TimeZone(identifier: "Pacific/Kiritimati")!, locale: locale), "Sep 9, 2026 – Sep 10, 2026")
        XCTAssertEqual(range.rangeLabel(at: observed, in: TimeZone(secondsFromGMT: 0)!, locale: locale), "Sep 9, 2026")
        let easternNow = try instant("2026-09-09T16:00:00Z")
        let eastern = PublishedDataRange(first: range.first, last: range.last, updatedAt: easternNow, scope: "fixture")
        XCTAssertEqual(eastern.rangeLabel(at: easternNow, in: TimeZone(identifier: "Asia/Tokyo")!, locale: locale), "Sep 9, 2026 – Sep 10, 2026")
    }

    func testLocalDateRangeSurvivesYearRolloverAndOfflineLegacyDecode() throws {
        let observed = try instant("2027-01-01T02:00:00Z"), locale = Locale(identifier: "en_US")
        let range = PublishedDataRange(first: try date("2027-01-01"), last: try date("2027-01-01"), updatedAt: nil, scope: "fixture", observedAt: observed)
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(range.rangeLabel(at: observed + 86400, in: zone, locale: locale), "Dec 31, 2026", "Offline time passing must not extend the uploaded range")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(range)) as? [String: Any])
        legacy.removeValue(forKey: "observedAt")
        let decoded = try JSONDecoder().decode(PublishedDataRange.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.observedAt)
        XCTAssertEqual(decoded.rangeLabel(at: observed, in: zone, locale: locale), "Dec 31, 2026")
    }

    func testConfirmedBoundaryIncludesLocalTimeAndRespectsDaylightSaving() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!, locale = Locale(identifier: "en_US")
        var value = SyncAvailability(since: try date("2026-03-08"), refreshedAt: now, scope: "fixture", historyComplete: false, hasSamples: true)
        let winter = value.sinceLabel(in: zone, locale: locale)
        XCTAssertTrue(winter.contains("Mar 7, 2026")); XCTAssertTrue(winter.contains("4:00"))
        value.since = try date("2026-03-09")
        let summer = value.sinceLabel(in: zone, locale: locale)
        XCTAssertTrue(summer.contains("Mar 8, 2026")); XCTAssertTrue(summer.contains("5:00"))
        value.since = try date("2026-09-10")
        XCTAssertTrue(value.sinceLabel(in: TimeZone(identifier: "Asia/Kolkata")!, locale: locale).contains("5:30"))
        XCTAssertEqual(value.sinceLabel(in: TimeZone(secondsFromGMT: 0)!, locale: locale), "Sep 10, 2026")
    }

    func testUpgradeShowsExistingUploadsBeforeCoverageMigrationOrRecentScan() async throws {
        let (store, url) = try await database()
        // An existing installation with thousands of acknowledged uploads,
        // but no range checkpoint from the new verification feature.
        try await store.execute("""
            WITH RECURSIVE days(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM days WHERE n<7185)
            INSERT INTO uploaded SELECT 'steps',date('2006-01-01','+'||n||' days'),1,date('2006-01-01','+'||n||' days'),date('2006-01-01','+'||n||' days') FROM days
            """)
        try await store.execute("DELETE FROM sync_metadata WHERE key='chunk-coverage-v1'")
        let reopened = try await SyncStore.open(url: url)
        let pending = try await reopened.pendingCoverageCount()
        XCTAssertEqual(pending, 7186)
        let range = try await reopened.publishedRange(for: [steps])
        XCTAssertEqual(range?.first, try date("2006-01-01"))
        XCTAssertEqual(range?.last, try date("2006-01-01") + 7185 * 86400)
        XCTAssertNil(range?.updatedAt, "Legacy timestamps must not be invented from app launch time")
        let completeRange = try await reopened.availability(for: [steps])
        XCTAssertNil(completeRange, "A published span does not prove complete coverage")
        try await reopened.resetIndex()
        let reset = try await reopened.publishedRange(for: [steps]); XCTAssertNil(reset)
    }

    func testPublishedCatalogRangeFiltersPrivateEmptyAndDisabledSeriesAndPersistsOffline() async throws {
        let (store, url) = try await database()
        let range = PublishedDataRange.fromCatalog([
            ["series": "steps", "total_samples": 10, "first_day": "2026-09-01", "last_day": "2026-09-09", "last_synced_at": now.timeIntervalSince1970 - 240],
            ["series": "profile", "total_samples": 1, "first_day": "2001-01-01", "last_day": "2030-01-01", "last_synced_at": now.timeIntervalSince1970],
            ["series": "body_mass", "total_samples": 1, "first_day": "2000-01-01", "last_day": "2031-01-01", "last_synced_at": now.timeIntervalSince1970],
            ["series": "daily_summary", "total_samples": 30, "first_day": "2000-01-01", "last_day": "2031-01-01", "last_synced_at": now.timeIntervalSince1970],
            ["series": "steps", "total_samples": 0, "first_day": "1999-01-01", "last_day": "2032-01-01"],
            ["series": "steps", "total_samples": 1, "first_day": "", "last_day": ""]
        ], definitions: [steps])
        XCTAssertEqual(range?.first, try date("2026-09-01")); XCTAssertEqual(range?.last, try date("2026-09-09"))
        XCTAssertEqual(range?.updatedAt, now - 240)
        XCTAssertNil(PublishedDataRange.fromCatalog([["series": "daily_summary", "total_samples": 30, "first_day": "2026-09-01", "last_day": "2026-09-30"]], definitions: [steps]))
        try await store.cachePublishedRange(range, definitions: [steps])
        let reopened = try await SyncStore.open(url: url)
        let cached = try await reopened.publishedRange(for: [steps]); XCTAssertEqual(cached, range)
        let disabled = try await reopened.publishedRange(for: [mass]); XCTAssertNil(disabled)
        // Server-confirmed emptiness takes precedence over stale local rows.
        try await store.recordUpload(DirtyChunk(series: "steps", period: "2020-01-01"), count: 1, first: "2020-01-01", last: "2020-01-01")
        try await store.cachePublishedRange(nil, definitions: [steps])
        let empty = try await reopened.publishedRange(for: [steps]); XCTAssertNil(empty)
    }

    func testRecentDataIsPublishedBeforeLegacyCoverageAndSurvivesMigrationFailure() async throws {
        let (store, _) = try await database()
        let old = DirtyChunk(series: "workouts", period: "2020-01-01/" + UUID().uuidString.lowercased())
        try await store.recordUpload(old, count: 1, first: "2020-01-01", last: "2020-01-01")
        try await store.execute("INSERT INTO coverage_pending VALUES(?,?)", [old.series, old.period])
        let uploader = AvailabilityUploader(failCoverage: true, store: store)
        let result = await SyncEngine(store: store, reader: AvailabilityReader(store: store), client: uploader, key: "synthetic", run: SyncRun(trigger: "App opened")) { _ in }.sync(definitions: [workouts], now: now)
        let ready = await uploader.readyBeforeCoverage
        XCTAssertTrue(ready, "Recent data must become usable before upgrading historical metadata")
        XCTAssertEqual(result.status, "failed")
        XCTAssertNotNil(result.availability, "A metadata failure cannot hide already confirmed recent data")
        let pending = try await store.pendingCoverageCount(); XCTAssertEqual(pending, 1, "Retry migration on the next run")
    }

    func testRangeNeedsEveryPeriodRecordScanAndCatalogAcknowledgement() async throws {
        let (store, _) = try await database(), definitions = [steps, mass, workouts]
        // An old upload alone must never be interpreted as a complete range.
        try await store.recordUpload(DirtyChunk(series: "steps", period: "2020-01-01"), count: 1, first: "2020-01-01", last: "2020-01-01")
        let before = try await store.availability(for: definitions); XCTAssertNil(before)
        _ = try await store.beginRecentScan(definitions: definitions, now: now)
        let chunks = try await store.nextRecentChunks(limit: 1000, excluding: [])
        for chunk in chunks.dropLast() { try await acknowledge(chunk, in: store, count: 0) }
        try await publishCatalog(store)
        var value = try await store.confirmRecentScan(definitions: definitions); XCTAssertNil(value)
        try await acknowledge(try XCTUnwrap(chunks.last), in: store, count: 0)
        try await publishCatalog(store)
        value = try await store.confirmRecentScan(definitions: definitions); XCTAssertNil(value, "Workouts have not been fully enumerated")
        try await store.stageRecentRecords(type: workouts.sampleType!.identifier, page: HealthPage(samples: [], deleted: [], anchor: nil, readCount: 0, hasMore: false))
        // Simulate an acknowledged upload whose catalog publication failed.
        try await acknowledge(chunks[0], in: store, count: 0)
        value = try await store.confirmRecentScan(definitions: definitions); XCTAssertNil(value)
        try await publishCatalog(store)
        value = try await store.confirmRecentScan(definitions: definitions)
        XCTAssertEqual(value?.since, BackfillPlan.recentStart(now: now))
        XCTAssertEqual(value?.refreshedAt, now)
        XCTAssertFalse(try XCTUnwrap(value).historyComplete)
    }

    func testPausedScanKeepsItsWindowPendingChunksAndSeparateRecordCursor() async throws {
        let (store, url) = try await database(), definitions = [steps, workouts]
        let started = try await store.beginRecentScan(definitions: definitions, now: now)
        let scan = try XCTUnwrap(started)
        let initial = try await store.nextRecentChunks(limit: 1000, excluding: [])
        for chunk in initial.prefix(3) { try await acknowledge(chunk, in: store) }
        let recordType = workouts.sampleType!.identifier
        try await store.stageRecentRecords(type: recordType, page: HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 1000), readCount: 1000, hasMore: true))
        let reopened = try await SyncStore.open(url: url)
        let resumed = try await reopened.beginRecentScan(definitions: definitions, now: now + 86400)
        XCTAssertEqual(resumed?.through, scan.through); XCTAssertEqual(resumed?.since, scan.since)
        let remaining = try await reopened.nextRecentChunks(limit: 1000, excluding: [])
        XCTAssertEqual(remaining.count, initial.count - 3)
        let cursor = try await reopened.recentCursor(for: recordType)
        XCTAssertNotNil(cursor.anchor); XCTAssertFalse(cursor.complete)
        let fullHistoryAnchor = try await reopened.anchor(for: recordType); XCTAssertNil(fullHistoryAnchor)
    }

    func testRangeSurvivesRelaunchButCannotApplyToNewSharingScopeOrResetCache() async throws {
        let (store, url) = try await database()
        let expected = try await confirm(store, definitions: [steps])
        let reopened = try await SyncStore.open(url: url)
        let restored = try await reopened.availability(for: [steps]); XCTAssertEqual(restored, expected)
        let different = try await reopened.availability(for: [steps, mass]); XCTAssertNil(different)
        try await reopened.clearSeries("steps")
        let cleared = try await reopened.availability(for: [steps]); XCTAssertNil(cleared)
        _ = try await confirm(reopened, definitions: [steps])
        try await reopened.resetIndex()
        let reset = try await reopened.availability(for: [steps]); XCTAssertNil(reset)
        let pending = try await reopened.nextRecentChunks(limit: 1000, excluding: []); XCTAssertTrue(pending.isEmpty)
    }

    func testHistoricalFrontierAccountsForMonthlyAndMultiDayGapsWithoutFakingFreshness() async throws {
        let (store, _) = try await database(), definitions = [steps]
        let first = try await confirm(store, definitions: definitions)
        let month = DirtyChunk(series: "body_mass", period: "2026-08")
        let day = DirtyChunk(series: "steps", period: "2026-08-29")
        let workout = DirtyChunk(series: "workouts", period: "2026-08-28/" + UUID().uuidString.lowercased())
        let sample = IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: workouts.sampleType!.identifier, series: workout.series, period: workout.period, start: try date("2026-08-28"), end: try date("2026-09-02") + 3600)
        try await store.applyPage(type: sample.hkType, samples: [sample], deleted: [], anchor: nil)
        // Keep just the explicit gaps; derived invalidations are tested elsewhere.
        try await store.execute("DELETE FROM dirty")
        for chunk in [month, day, workout] { try await store.markDirty(chunk.series, chunk.period) }
        var value = try await store.extendAvailability(definitions: definitions)
        XCTAssertEqual(value?.since, first.since, "The multi-day workout blocks through September 2")
        try await acknowledge(workout, in: store); try await publishCatalog(store)
        value = try await store.extendAvailability(definitions: definitions)
        XCTAssertEqual(value?.since, try date("2026-09-01"), "A monthly gap takes precedence over a daily key that sorts later")
        try await acknowledge(month, in: store); try await publishCatalog(store)
        value = try await store.extendAvailability(definitions: definitions)
        XCTAssertEqual(value?.since, try date("2026-08-30"))
        XCTAssertEqual(value?.refreshedAt, first.refreshedAt, "Publishing old history must not refresh today's timestamp")
        try await acknowledge(day, in: store); try await publishCatalog(store)
        value = try await store.extendAvailability(definitions: definitions, refreshedAt: now + 3600)
        XCTAssertTrue(try XCTUnwrap(value).historyComplete)
        XCTAssertEqual(value?.refreshedAt, now + 3600)
        let next = try await store.beginRecentScan(definitions: definitions, now: now + 7200)
        XCTAssertNil(next, "Once history is complete, use anchored deltas instead of rescanning seven days")
        try await store.seedRecent(BackfillPlan.recentChunks(definitions: definitions, now: now + 7200), day: HealthDates.day(now + 7200))
        let extraWork = try await store.dirtyCount()
        XCTAssertEqual(extraWork, 0, "The completed recent scan already seeded this UTC day")
    }

    func testRecentRecordsPagePastEightAndBecomeUsableBeforeFullEnumeration() async throws {
        let (store, _) = try await database(), reader = AvailabilityReader(store: store), uploader = AvailabilityUploader()
        let engine = SyncEngine(store: store, reader: reader, client: uploader, key: "synthetic", run: SyncRun(trigger: "Initial backfill")) { _ in }
        let result = await engine.sync(definitions: [workouts], now: now)
        XCTAssertEqual(result.status, "complete")
        let pages = await reader.recentPages, ready = await reader.readyBeforeHistory
        XCTAssertEqual(pages, 2); XCTAssertTrue(ready)
        let records = await uploader.workoutUploads; XCTAssertEqual(records.count, 18)
        XCTAssertEqual(result.availability?.refreshedAt, now)
    }

    func testFailedCatalogCannotClaimRecentDataIsReady() async throws {
        let (store, _) = try await database(), uploader = AvailabilityUploader(failCatalog: true)
        let result = await SyncEngine(store: store, reader: AvailabilityReader(store: store), client: uploader, key: "synthetic", run: SyncRun(trigger: "Initial backfill")) { _ in }.sync(definitions: [workouts], now: now)
        XCTAssertEqual(result.status, "failed")
        let availability = try await store.availability(for: [workouts]); XCTAssertNil(availability)
        XCTAssertNil(result.availability)
    }

    func testEmptySharedRangeDoesNotSayReadyAndRelativeAgeAdvances() async throws {
        let (store, _) = try await database()
        _ = try await store.beginRecentScan(definitions: [steps], now: now)
        for chunk in try await store.nextRecentChunks(limit: 1000, excluding: []) { try await acknowledge(chunk, in: store, count: 0) }
        try await publishCatalog(store)
        let confirmed = try await store.confirmRecentScan(definitions: [steps])
        let value = try XCTUnwrap(confirmed)
        XCTAssertFalse(value.hasSamples)
        XCTAssertEqual(value.freshnessLabel(at: now - 60), "Just now")
        XCTAssertEqual(value.freshnessLabel(at: now + 240), "4 mins ago")
        XCTAssertEqual(value.freshnessLabel(at: now + 3600), "1 hour ago")
        XCTAssertEqual(value.freshnessLabel(at: now + 86400), "1 day ago")
    }
}

private actor AvailabilityReader: HealthSyncReading {
    let store: SyncStore
    var recentPages = 0
    var readyBeforeHistory = false
    init(store: SyncStore) { self.store = store }
    func readRecentRecordPage(definition: SeriesDefinition, since: Date, through: Date, anchor: HKQueryAnchor?) -> HealthPage {
        recentPages += 1
        let samples = (0..<9).map { index -> IndexedSample in
            let uuid = UUID().uuidString.lowercased(), time = since + Double(index + recentPages * 20) * 60
            return IndexedSample(uuid: uuid, hkType: definition.sampleType!.identifier, series: definition.id, period: HealthDates.day(time) + "/" + uuid, start: time, end: time + 30)
        }
        return HealthPage(samples: samples, deleted: [], anchor: HKQueryAnchor(fromValue: recentPages), readCount: samples.count, hasMore: recentPages < 2)
    }
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) async throws -> HealthPage {
        readyBeforeHistory = try await store.availability(for: definitions) != nil
        return HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 100), readCount: 0, hasMore: false)
    }
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) throws -> PreparedChunk {
        let day = HealthDates.day(try HealthDates.bounds(chunk.period).0)
        return PreparedChunk(data: Data("[{}]".utf8), count: 1, first: day, last: day)
    }
    func readProfile() -> Data { Data("{}".utf8) }
}
private actor AvailabilityUploader: SyncUploading {
    let failCatalog: Bool
    let failCoverage: Bool
    let store: SyncStore?
    var readyBeforeCoverage = false
    var workoutUploads = Set<String>()
    init(failCatalog: Bool = false, failCoverage: Bool = false, store: SyncStore? = nil) { self.failCatalog = failCatalog; self.failCoverage = failCoverage; self.store = store }
    func upload(series: String, period: String, plaintext: Data, key: String) -> Int { if series == "workouts" { workoutUploads.insert(period) }; return plaintext.count }
    func delete(series: String, period: String) {}
    func updateCatalog(_ summary: UploadedSummary) throws { if failCatalog { throw HealthMCPError.message("Synthetic catalog failure") } }
    func updateCoverage(_ coverage: [ChunkCoverage]) async throws -> [DirtyChunk] {
        readyBeforeCoverage = try await store?.availability(for: SeriesDefinition.all.filter { $0.id == "workouts" }) != nil
        if failCoverage { throw HealthMCPError.message("Synthetic coverage failure") }
        return []
    }
    func completeSync() {}
}
