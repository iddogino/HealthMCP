import XCTest
import HealthKit
@testable import HealthMCP

final class FreshDataPriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_955_200)
    private var steps: SeriesDefinition { SeriesDefinition.quantities.first { $0.id == "steps" }! }
    private var workouts: SeriesDefinition { SeriesDefinition.all.first { $0.id == "workouts" }! }
    private func database() async throws -> (SyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite")
        return (try await SyncStore.open(url: url), url)
    }
    private func acknowledge(_ chunks: [DirtyChunk], store: SyncStore) async throws {
        for chunk in chunks {
            let day = HealthDates.day(try HealthDates.bounds(chunk.period).0)
            try await store.recordUpload(chunk, count: 1, first: day, last: day)
        }
        for series in try await store.pendingCatalog() { try await store.acknowledgeCatalog(series) }
    }
    private func confirmInitial(_ store: SyncStore, definitions: [SeriesDefinition]) async throws {
        _ = try await store.beginRecentScan(definitions: definitions, now: now)
        for definition in definitions where definition.chunk == "record" {
            try await store.stageRecentRecords(type: definition.sampleType!.identifier, page: HealthPage(samples: [], deleted: [], anchor: nil, readCount: 0, hasMore: false))
        }
        try await acknowledge(store.nextRecentChunks(limit: 1000, excluding: []), store: store)
        let value = try await store.confirmRecentScan(definitions: definitions)
        XCTAssertNotNil(value)
    }

    func testFifteenHourCatchupFinishesBeforeResumingYesterdayOrHistory() async throws {
        let (store, _) = try await database(), definitions = [steps, workouts]
        _ = try await store.beginRecentScan(definitions: definitions, now: now - 15 * 3600)
        let events = FreshEvents(), clock = FreshClock(now)
        let reader = FreshReader(events: events, store: store, definitions: definitions)
        let result = await SyncEngine(store: store, reader: reader, client: FreshUploader(), key: "fixture", run: SyncRun(trigger: "App opened")) { _ in }.sync(definitions: definitions, now: now, clock: { clock.read() })
        let log = await events.values
        let current = try XCTUnwrap(log.firstIndex(of: "chunk:steps/\(HealthDates.day(now))"))
        let older = try XCTUnwrap(log.firstIndex(of: "chunk:steps/\(HealthDates.day(now - 6 * 86400))"))
        XCTAssertLessThan(current, older)
        XCTAssertTrue(log.contains("history-freshness:\(now.timeIntervalSince1970)"))
        XCTAssertEqual(result.availability?.refreshedAt, now)
        XCTAssertEqual(result.status, "complete")
    }

    func testNewWindowPreemptsPausedWorkWithoutLosingItsRecordCursor() async throws {
        let (store, url) = try await database(), definitions = [steps, workouts]
        try await confirmInitial(store, definitions: definitions)
        let firstResult = try await store.prepareFreshWindow(definitions: definitions, through: now + 3600, enqueue: true)
        let first = try XCTUnwrap(firstResult), type = workouts.sampleType!.identifier
        try await store.stageFreshRecords(window: first.id, type: type, page: HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 1000), readCount: 1000, hasMore: true))
        let reopened = try await SyncStore.open(url: url)
        let latestResult = try await reopened.prepareFreshWindow(definitions: definitions, through: now + 7200, enqueue: true)
        let latest = try XCTUnwrap(latestResult)
        XCTAssertNotEqual(first.id, latest.id)
        XCTAssertEqual(latest.since, first.through)
        let preserved = try await reopened.freshCursor(window: first.id, type: type)
        XCTAssertNotNil(preserved.anchor); XCTAssertFalse(preserved.complete)
        let fresh = try await reopened.freshCursor(window: latest.id, type: type)
        XCTAssertNil(fresh.anchor)
        try await acknowledge(reopened.nextFreshChunks(window: latest.id, limit: 1000, excluding: []), store: reopened)
        try await reopened.stageFreshRecords(window: latest.id, type: type, page: HealthPage(samples: [], deleted: [], anchor: nil, readCount: 0, hasMore: false))
        let newestDone = try await reopened.confirmFreshWindow(latest, definitions: definitions)
        XCTAssertTrue(newestDone)
        let stillOld = try await reopened.availability(for: definitions)
        XCTAssertEqual(stillOld?.refreshedAt, now, "An unfinished older catch-up window still leaves a gap")
        let resumed = try await reopened.prepareFreshWindow(definitions: definitions, through: now + 7200, enqueue: false)
        XCTAssertEqual(resumed?.id, first.id)
        try await acknowledge(reopened.nextFreshChunks(window: first.id, limit: 1000, excluding: []), store: reopened)
        try await reopened.stageFreshRecords(window: first.id, type: type, page: HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 1001), readCount: 0, hasMore: false))
        let olderDone = try await reopened.confirmFreshWindow(first, definitions: definitions)
        XCTAssertTrue(olderDone)
        let complete = try await reopened.availability(for: definitions)
        XCTAssertEqual(complete?.refreshedAt, now + 7200)
        let anchor = try await reopened.anchor(for: type)
        XCTAssertNil(anchor, "Recent predicates must not overwrite the full-history anchor")
    }

    func testLongBackfillChecksNewDataBeforeTheNextHistoryPage() async throws {
        try await verifyInterruption(seconds: 600, request: false)
    }

    func testForegroundRequestPreemptsBeforeThePeriodicDeadline() async throws {
        try await verifyInterruption(seconds: 120, request: true)
    }

    private func verifyInterruption(seconds: TimeInterval, request: Bool) async throws {
        let (store, _) = try await database(), definitions = [steps], clock = FreshClock(now), events = FreshEvents()
        try await confirmInitial(store, definitions: definitions)
        let reader = FreshReader(events: events, store: store, definitions: definitions)
        let engine = SyncEngine(store: store, reader: reader, client: FreshUploader(), key: "fixture", run: SyncRun(trigger: "App opened")) { _ in }
        await reader.setFirstPageHook {
            clock.advance(seconds)
            if request { await engine.requestRecentRefresh() }
        }
        let result = await engine.sync(definitions: definitions, now: now, clock: { clock.read() })
        let log = await events.values
        XCTAssertTrue(log.contains("history-freshness:\((now + seconds).timeIntervalSince1970)"), "The next history page must wait for the fresh-data catch-up")
        XCTAssertEqual(result.availability?.refreshedAt, now + seconds, "Final full-sync bookkeeping must not restore its old start timestamp")
        XCTAssertEqual(result.status, "complete")
    }

    func testFailedFreshPublicationPreventsHistoricalWorkAndDoesNotAdvanceFreshness() async throws {
        let (store, _) = try await database(), definitions = [steps], events = FreshEvents()
        try await confirmInitial(store, definitions: definitions)
        let result = await SyncEngine(store: store, reader: FreshReader(events: events, store: store, definitions: definitions), client: FreshUploader(failCatalog: true), key: "fixture", run: SyncRun(trigger: "App opened")) { _ in }.sync(definitions: definitions, now: now + 15 * 3600)
        let log = await events.values
        XCTAssertFalse(log.contains { $0.hasPrefix("history-") })
        XCTAssertEqual(result.availability?.refreshedAt, now)
        XCTAssertEqual(result.status, "failed")
        let pending = try await store.prepareFreshWindow(definitions: definitions, through: now + 15 * 3600, enqueue: false)
        XCTAssertNotNil(pending, "Retry must retain the unconfirmed work")
    }

    func testPrivacyResetRemovesAllFreshWindowsAndProgress() async throws {
        let (store, _) = try await database(), definitions = [steps]
        try await confirmInitial(store, definitions: definitions)
        _ = try await store.prepareFreshWindow(definitions: definitions, through: now + 3600, enqueue: true)
        try await store.clearSeries(steps.id)
        for table in ["fresh_windows", "fresh_pending", "fresh_cursors"] {
            let rows = try await store.rows("SELECT COUNT(*) AS count FROM \(table)")
            XCTAssertEqual(rows.first?["count"] as? Int, 0)
        }
    }
}

private final class FreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date += seconds }
}
private actor FreshEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private actor FreshReader: HealthSyncReading {
    let events: FreshEvents, store: SyncStore, definitions: [SeriesDefinition]
    private var pages = 0
    private var firstPageHook: (@Sendable () async -> Void)?
    init(events: FreshEvents, store: SyncStore, definitions: [SeriesDefinition]) { self.events = events; self.store = store; self.definitions = definitions }
    func setFirstPageHook(_ hook: @escaping @Sendable () async -> Void) { firstPageHook = hook }
    func readProfile() -> Data { Data("{}".utf8) }
    func readRecentRecordPage(definition: SeriesDefinition, since: Date, through: Date, anchor: HKQueryAnchor?) -> HealthPage { HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 1), readCount: 0, hasMore: false) }
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) async throws -> HealthPage {
        let freshness = try await store.availability(for: self.definitions)?.refreshedAt.timeIntervalSince1970 ?? 0
        await events.append("history-freshness:\(freshness)")
        pages += 1
        if pages == 1 { let hook = firstPageHook; firstPageHook = nil; await hook?() }
        return HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: pages), readCount: 0, hasMore: pages == 1)
    }
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) async throws -> PreparedChunk {
        await events.append("chunk:\(chunk.id)")
        let day = HealthDates.day(try HealthDates.bounds(chunk.period).0)
        return PreparedChunk(data: Data("[{}]".utf8), count: 1, first: day, last: day)
    }
}
private actor FreshUploader: SyncUploading {
    let failCatalog: Bool
    init(failCatalog: Bool = false) { self.failCatalog = failCatalog }
    func upload(series: String, period: String, plaintext: Data, key: String) -> Int { plaintext.count }
    func delete(series: String, period: String) {}
    func updateCatalog(_ summary: UploadedSummary) throws { if failCatalog { throw HealthMCPError.message("Synthetic catalog failure") } }
    func completeSync() {}
}

extension FreshDataPriorityTests {
    func testLongGapRunsNewestFirstAndSurvivesRelaunchUntilEveryMissingDateIsAcknowledged() async throws {
        let (store, url) = try await database(), definitions = [steps]
        try await confirmInitial(store, definitions: definitions)
        let resumedAt = now + 14 * 86400
        let newestResult = try await store.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: true)
        let newest = try XCTUnwrap(newestResult)
        XCTAssertEqual(newest.since, BackfillPlan.recentStart(now: resumedAt))
        try await acknowledge(store.nextFreshChunks(window: newest.id, limit: 1000, excluding: []), store: store)
        let newestConfirmed = try await store.confirmFreshWindow(newest, definitions: definitions)
        XCTAssertTrue(newestConfirmed)
        let reopened = try await SyncStore.open(url: url)
        let gapResult = try await reopened.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: true)
        let gap = try XCTUnwrap(gapResult)
        XCTAssertEqual(gap.since, now)
        XCTAssertEqual(gap.through, newest.since)
        let before = try await reopened.availability(for: definitions)
        XCTAssertEqual(before?.refreshedAt, now)
        let pending = try await reopened.nextFreshChunks(window: gap.id, limit: 1000, excluding: [])
        XCTAssertTrue(pending.contains(DirtyChunk(series: "steps", period: HealthDates.day(now + 2 * 86400))))
        try await acknowledge(pending, store: reopened)
        let confirmed = try await reopened.confirmFreshWindow(gap, definitions: definitions)
        XCTAssertTrue(confirmed)
        let after = try await reopened.availability(for: definitions)
        XCTAssertEqual(after?.since, BackfillPlan.recentStart(now: now))
        XCTAssertEqual(after?.refreshedAt, resumedAt)
        let finished = try await reopened.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: false)
        XCTAssertNil(finished)
    }

    func testUpgradeRepairsClippedPendingWindowsWithoutReplacingTheirCursors() async throws {
        let (store, _) = try await database(), definitions = [steps, workouts]
        try await confirmInitial(store, definitions: definitions)
        let resumedAt = now + 14 * 86400, since = BackfillPlan.recentStart(now: now + 14 * 86400)
        let scope = SyncAvailability.scope(for: definitions)
        try await store.execute("INSERT INTO fresh_windows(id,since,through,scope) VALUES('legacy',?,?,?)", [since.timeIntervalSince1970, resumedAt.timeIntervalSince1970, scope])
        let type = workouts.sampleType!.identifier
        try await store.stageFreshRecords(window: "legacy", type: type, page: HealthPage(samples: [], deleted: [], anchor: HKQueryAnchor(fromValue: 1000), readCount: 1000, hasMore: true))
        let newest = try await store.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: true)
        XCTAssertEqual(newest?.id, "legacy")
        let cursor = try await store.freshCursor(window: "legacy", type: type)
        XCTAssertNotNil(cursor.anchor)
        XCTAssertFalse(cursor.complete)
        let gaps = try await store.rows("SELECT since,through FROM fresh_windows WHERE id!='legacy'")
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?["since"] as? Double, now.timeIntervalSince1970)
        XCTAssertEqual(gaps.first?["through"] as? Double, since.timeIntervalSince1970)
    }

    func testUpgradeRevalidatesLegacyCoverageWithoutDiscardingUploadedHistory() async throws {
        let (store, url) = try await database(), definitions = [steps]
        try await confirmInitial(store, definitions: definitions)
        let original = SyncAvailability(since: now - 365 * 86400, refreshedAt: now, scope: SyncAvailability.scope(for: definitions), historyComplete: true, hasSamples: true)
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        try await store.execute("UPDATE sync_metadata SET value=? WHERE key='availability-v1'", [encoded])
        try await store.execute("DELETE FROM sync_metadata WHERE key='availability-continuity-v2'")
        let before = try await store.publishedRange(for: definitions)
        let reopened = try await SyncStore.open(url: url)
        let after = try await reopened.availability(for: definitions)
        XCTAssertEqual(after?.since, BackfillPlan.recentStart(now: now))
        XCTAssertEqual(after?.refreshedAt, now)
        XCTAssertEqual(after?.historyComplete, false)
        let uploaded = try await reopened.publishedRange(for: definitions)
        XCTAssertEqual(uploaded?.first, before?.first)
        XCTAssertEqual(uploaded?.last, before?.last)
        XCTAssertEqual(uploaded?.scope, before?.scope)
    }

    func testReviewLongAbsenceDoesNotBridgeAnUnscannedGap() async throws {
        let (store, _) = try await database(), definitions = [steps]
        try await confirmInitial(store, definitions: definitions)
        let beforeResult = try await store.availability(for: definitions)
        let before = try XCTUnwrap(beforeResult)
        let resumedAt = now + 14 * 86400
        let result = try await store.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: true)
        let window = try XCTUnwrap(result)
        try await acknowledge(store.nextFreshChunks(window: window.id, limit: 1000, excluding: []), store: store)
        let confirmed = try await store.confirmFreshWindow(window, definitions: definitions)
        XCTAssertTrue(confirmed)
        let afterResult = try await store.availability(for: definitions)
        let after = try XCTUnwrap(afterResult)
        print("REVIEW_GAP resume before=\(HealthDates.timestamp(before.refreshedAt)) scanned_since=\(HealthDates.timestamp(window.since)) claimed_since=\(HealthDates.timestamp(after.since)) claimed_through=\(HealthDates.timestamp(after.refreshedAt))")
        XCTAssertTrue(after.refreshedAt <= before.refreshedAt || after.since >= window.since,
                      "A recent-only catch-up cannot claim continuous coverage across the unscanned dates between the old checkpoint and its clipped start")
    }

    func testReviewInterruptedOnboardingDoesNotBridgeAnUnscannedGap() async throws {
        let (store, _) = try await database(), definitions = [steps]
        _ = try await store.beginRecentScan(definitions: definitions, now: now)
        let resumedAt = now + 14 * 86400
        let result = try await store.prepareFreshWindow(definitions: definitions, through: resumedAt, enqueue: true)
        let window = try XCTUnwrap(result)
        try await acknowledge(store.nextFreshChunks(window: window.id, limit: 1000, excluding: []), store: store)
        let freshConfirmed = try await store.confirmFreshWindow(window, definitions: definitions)
        XCTAssertTrue(freshConfirmed)
        try await acknowledge(store.nextRecentChunks(limit: 1000, excluding: []), store: store)
        let initialResult = try await store.confirmRecentScan(definitions: definitions)
        let after = try XCTUnwrap(initialResult)
        print("REVIEW_GAP onboarding old_scan_through=\(HealthDates.timestamp(now)) new_scan_since=\(HealthDates.timestamp(window.since)) claimed_since=\(HealthDates.timestamp(after.since)) claimed_through=\(HealthDates.timestamp(after.refreshedAt))")
        XCTAssertTrue(after.refreshedAt <= now || after.since >= window.since,
                      "Finishing an old initial window cannot merge two disjoint verified intervals into one complete range")
    }
}
