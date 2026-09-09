import XCTest
import HealthKit
@testable import HealthMCP

final class SyncAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_955_200) // Sep 9, 2026 at noon UTC
    private var steps: SeriesDefinition { SeriesDefinition.quantities.first { $0.id == "steps" }! }
    private var mass: SeriesDefinition { SeriesDefinition.quantities.first { $0.id == "body_mass" }! }
    private var workouts: SeriesDefinition { SeriesDefinition.all.first { $0.id == "workouts" }! }
    private func date(_ day: String) throws -> Date { try HealthDates.bounds(day).0 }
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
    var workoutUploads = Set<String>()
    init(failCatalog: Bool = false) { self.failCatalog = failCatalog }
    func upload(series: String, period: String, plaintext: Data, key: String) -> Int { if series == "workouts" { workoutUploads.insert(period) }; return plaintext.count }
    func delete(series: String, period: String) {}
    func updateCatalog(_ summary: UploadedSummary) throws { if failCatalog { throw HealthMCPError.message("Synthetic catalog failure") } }
    func completeSync() {}
}
