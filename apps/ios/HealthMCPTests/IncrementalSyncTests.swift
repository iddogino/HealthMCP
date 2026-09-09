import XCTest
import HealthKit
import SQLite3
@testable import HealthMCP

private actor SyncEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private actor FixtureHealthReader: HealthSyncReading {
    let events: SyncEvents
    var page = 0
    let pauseAfter: Int?
    let blockChunks: Bool
    init(events: SyncEvents, pauseAfter: Int? = nil, blockChunks: Bool = false) { self.events = events; self.pauseAfter = pauseAfter; self.blockChunks = blockChunks }
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) async throws -> HealthPage {
        if let pauseAfter, page == pauseAfter { throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue) }
        page += 1
        await events.append("page:\(page)")
        let date = Date(timeIntervalSince1970: 1_500_000_000 + Double(page) * 86400)
        let definition = definitions[0]
        let sample = IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: definition.sampleType!.identifier, series: definition.id, period: HealthDates.day(date), start: date, end: date + 60)
        return HealthPage(samples: [sample], deleted: [], anchor: HKQueryAnchor(fromValue: page), readCount: 1, hasMore: page < 12)
    }
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) async throws -> PreparedChunk {
        if blockChunks { await events.append("blocked-read"); try await Task.sleep(for: .seconds(60)) }
        return PreparedChunk(data: Data("[{\"v\":1}]".utf8), count: 1, first: "2026-09-01", last: "2026-09-01")
    }
    func readProfile() -> Data { Data("{}".utf8) }
    func readRecentRecordPage(definition: SeriesDefinition, since: Date, through: Date, anchor: HKQueryAnchor?) -> HealthPage { HealthPage(samples: [], deleted: [], anchor: nil, readCount: 0, hasMore: false) }
}
private actor FixtureUploader: SyncUploading {
    let events: SyncEvents
    var summaries: [UploadedSummary] = []
    init(events: SyncEvents) { self.events = events }
    func upload(series: String, period: String, plaintext: Data, key: String) async throws -> Int { await events.append("upload:\(series)"); return plaintext.count }
    func delete(series: String, period: String) async throws { await events.append("delete:\(series)") }
    func updateCatalog(_ summary: UploadedSummary) async throws { summaries.append(summary); await events.append("catalog:\(summary.series)") }
    func completeSync() async throws { await events.append("complete") }
}

final class IncrementalSyncTests: XCTestCase {
    func testRestartPublishesAcknowledgedUploadsAndDeletionsMissingFromCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite")
        let original = try await SyncStore.open(url: url)
        try await original.recordUpload(DirtyChunk(series: "body_mass", period: "2026-08"), count: 7, first: "2026-08-01", last: "2026-08-31")
        try await original.recordUpload(DirtyChunk(series: "height", period: "2026-08"), count: 0, first: "2026-08-01", last: "2026-08-31")
        // Simulate termination after the blob acknowledgement but before its catalog PUT.
        let reopened = try await SyncStore.open(url: url), events = SyncEvents()
        let uploader = FixtureUploader(events: events)
        let engine = SyncEngine(store: reopened, reader: FixtureHealthReader(events: events), client: uploader, key: "synthetic-test-key", run: SyncRun(trigger: "App opened")) { _ in }
        let result = await engine.sync(definitions: [])
        let summaries = await uploader.summaries
        XCTAssertEqual(summaries.first { $0.series == "body_mass" }?.count, 7)
        XCTAssertEqual(summaries.first { $0.series == "height" }?.count, 0)
        let pending = try await reopened.pendingCatalog()
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(result.status, "complete")
    }
    func testCancelBlockedReadReturnsPromptlyAndRetainsPendingChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite")), events = SyncEvents()
        let definition = SeriesDefinition.quantities.first { $0.id == "steps" }!
        let engine = SyncEngine(store: store, reader: FixtureHealthReader(events: events, blockChunks: true), client: FixtureUploader(events: events), key: "synthetic-test-key", run: SyncRun(trigger: "Initial backfill")) { _ in }
        let task = Task { await engine.sync(definitions: [definition]) }
        for _ in 0..<100 {
            if await events.values.contains("blocked-read") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let beganRead = await events.values.contains("blocked-read"); XCTAssertTrue(beganRead)
        let start = ContinuousClock.now; task.cancel(); let result = await task.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.status, "paused"); XCTAssertTrue(result.errors.isEmpty)
        let pending = try await store.dirtyCount(); XCTAssertGreaterThan(pending, 0)
    }
    func testUploadsAndCatalogArePublishedBeforeEnumerationCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite"))
        let events = SyncEvents(), definition = SeriesDefinition.quantities.first { $0.id == "steps" }!
        let uploader = FixtureUploader(events: events)
        let engine = SyncEngine(store: store, reader: FixtureHealthReader(events: events), client: uploader, key: "synthetic-test-key", run: SyncRun(trigger: "Initial backfill")) { _ in }
        let result = await engine.sync(definitions: [definition])
        let log = await events.values
        let lastPage = try XCTUnwrap(log.lastIndex(of: "page:12"))
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "upload:steps")), lastPage)
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "catalog:steps")), lastPage)
        let middle = try XCTUnwrap(log.firstIndex(of: "page:6")), next = try XCTUnwrap(log.firstIndex(of: "page:7"))
        XCTAssertTrue(log[(middle + 1)..<next].contains { $0.hasPrefix("upload:") })
        XCTAssertEqual(result.status, "complete"); XCTAssertEqual(log.last, "complete")
        let pending = try await store.dirtyCount(); XCTAssertEqual(pending, 0)
        let summary = try await store.uploadedSummary("steps")
        XCTAssertEqual(summary.count, 19, "Seven recent chunks and twelve history chunks should count once each")
    }
    func testLockPauseKeepsCommittedAnchorAndPublishedChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite"), events = SyncEvents()
        var store: SyncStore? = try await SyncStore.open(url: url)
        let definition = SeriesDefinition.quantities.first { $0.id == "steps" }!
        let engine = SyncEngine(store: store!, reader: FixtureHealthReader(events: events, pauseAfter: 2), client: FixtureUploader(events: events), key: "synthetic-test-key", run: SyncRun(trigger: "Initial backfill")) { _ in }
        let result = await engine.sync(definitions: [definition])
        XCTAssertEqual(result.status, "paused"); XCTAssertTrue(result.errors.isEmpty)
        let before = try await store!.uploadedSummary("steps")
        XCTAssertGreaterThan(before.count, 0)
        store = nil
        let reopened = try await SyncStore.open(url: url)
        let anchor = try await reopened.anchor(for: definition.sampleType!.identifier)
        XCTAssertNotNil(anchor)
        let after = try await reopened.uploadedSummary("steps")
        XCTAssertEqual(before.count, after.count)
        let log = await events.values; XCTAssertFalse(log.contains("complete"))
    }
    func testLegacyMigrationPreservesAnchorsAndPendingWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE samples(uuid TEXT,hk_type TEXT,series TEXT,period TEXT,t0 REAL,t1 REAL,PRIMARY KEY(uuid,series));
        CREATE TABLE dirty(series TEXT,period TEXT,PRIMARY KEY(series,period));
        INSERT INTO samples VALUES('legacy-clean','steps','steps','2026-09-01',1788220800,1788220860);
        INSERT INTO samples VALUES('legacy-pending','steps','steps','2026-09-02',1788307200,1788307260);
        INSERT INTO dirty VALUES('steps','2026-09-02');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try await SyncStore.open(url: url)
        let count = try await store.totalSamples(), pending = try await store.dirtyCount(), uploaded = try await store.uploadedSummary("steps")
        XCTAssertEqual(count, 2); XCTAssertEqual(pending, 1); XCTAssertEqual(uploaded.count, 1)
        let reopened = try await SyncStore.open(url: url)
        let secondCount = try await reopened.totalSamples(); XCTAssertEqual(secondCount, 2)
    }
}
