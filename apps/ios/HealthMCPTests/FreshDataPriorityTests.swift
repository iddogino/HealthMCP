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
