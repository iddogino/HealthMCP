import XCTest
import HealthKit
@testable import HealthMCP

private final class MemorySecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var locked = false
    var failRemoval: String?
    func read(_ name: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if locked { throw HealthMCPError.message("Test storage locked") }; return values[name]
    }
    func set(_ name: String, _ value: Data) throws { lock.lock(); defer { lock.unlock() }; values[name] = value }
    func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemoval == name { failRemoval = nil; throw HealthMCPError.message("Test local cleanup failure") }
        values.removeValue(forKey: name)
    }
}
private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((RecoveryURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.handler?(self) } }
    override func stopLoading() {}
    func respond(_ status: Int = 200, body: String = "{}") {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor final class ReleaseRecoveryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var secrets: MemorySecrets!
    private var session: URLSession!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "cc.healthmcp.tests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
        secrets = MemorySecrets()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryURLProtocol.self]; session = URLSession(configuration: config)
        RecoveryURLProtocol.handler = { $0.respond() }
    }
    override func tearDown() async throws {
        session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
    }
    private func model() -> AppModel { AppModel(preferences: defaults, secureStorage: secrets, journalURL: directory.appendingPathComponent("sync.sqlite"), apiBaseURL: URL(string: "https://test.invalid")!, apiSession: session, allowsBackgroundWork: false) }
    private func registered() throws {
        _ = try DeviceIdentity(storage: secrets)
        try secrets.set("user-id", Data("u_test".utf8)); try secrets.set("health-key", Data(HealthCrypto.generateKey().utf8))
        defaults.set(true, forKey: "onboarded"); defaults.set(3, forKey: "onboardingStep")
    }
    func testRestoredPreferencesWithoutDeviceCredentialsRestartOnboarding() async throws {
        defaults.set(true, forKey: "onboarded"); defaults.set(3, forKey: "onboardingStep")
        let app = model(); await app.bootstrap()
        XCTAssertTrue(app.initialized); XCTAssertFalse(app.onboarded); XCTAssertEqual(app.onboardingStep, 0)
        XCTAssertEqual(app.api?.userID, ""); XCTAssertFalse(defaults.bool(forKey: "onboarded"))
    }
    func testFailedBootstrapRetriesAndConcurrentCallersWaitForReady() async throws {
        secrets.locked = true
        let app = model(); await app.bootstrap()
        XCTAssertFalse(app.initialized); XCTAssertNotNil(app.startupError)
        secrets.locked = false
        let first = Task { await app.bootstrap(); return app.initialized }
        let second = Task { await app.bootstrap(); return app.initialized }
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [true, true]); XCTAssertNil(app.startupError); XCTAssertFalse(app.privateKey.isEmpty)
    }
    func testPrivacyGatePrecedesNetworkAndSurvivesFailureAndRelaunch() async throws {
        try registered(); defaults.set(["nutrition"], forKey: "enabledGroups")
        let app = model(); await app.bootstrap()
        let entered = expectation(description: "Privacy request started")
        var held: RecoveryURLProtocol?
        RecoveryURLProtocol.handler = { request in held = request; entered.fulfill() }
        let privacy = Task { await app.setGroup("nutrition", enabled: false) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(app.pendingPrivacy); XCTAssertTrue(app.busy)
        for trigger in ["App opened", "Health data changed", "Agent requested sync"] { app.startSync(trigger: trigger) }
        XCTAssertFalse(app.isSyncing)
        held?.respond(500, body: "{\"error\":\"offline\"}"); await privacy.value
        app.startSync(trigger: "Manual retry"); XCTAssertFalse(app.isSyncing); XCTAssertNotNil(try secrets.read("privacy-operation"))
        RecoveryURLProtocol.handler = { $0.respond() }
        let restored = model(); await restored.bootstrap()
        XCTAssertTrue(restored.initialized); XCTAssertNil(restored.pendingPrivacy); XCTAssertFalse(restored.groups.contains("nutrition"))
        XCTAssertNil(try secrets.read("privacy-operation")); XCTAssertEqual(restored.api?.userID, "u_test")
    }
    func testConfirmedDeletionFinishesLocalCleanupAfterPartialCredentialRemoval() async throws {
        try registered(); let app = model(); await app.bootstrap()
        var deletes = 0; RecoveryURLProtocol.handler = { request in deletes += 1; request.respond() }
        secrets.failRemoval = "health-key"
        await app.deleteAccount()
        XCTAssertEqual(deletes, 1); XCTAssertEqual(app.pendingPrivacy?.remoteConfirmed, true)
        XCTAssertNil(try secrets.read("user-id")); XCTAssertNotNil(try secrets.read("privacy-operation"))
        let restored = model(); await restored.bootstrap()
        XCTAssertTrue(restored.initialized); XCTAssertFalse(restored.onboarded); XCTAssertEqual(restored.api?.userID, "")
        XCTAssertNil(restored.pendingPrivacy); XCTAssertEqual(deletes, 1, "Confirmed deletion must not depend on removed signing credentials")
    }
    func testLostDeleteResponseKeepsCredentialsUntilAuthenticatedRetrySucceeds() async throws {
        try registered(); let app = model(); await app.bootstrap()
        RecoveryURLProtocol.handler = { request in request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost)) }
        await app.deleteAccount()
        XCTAssertNotNil(try secrets.read("user-id")); XCTAssertEqual(app.pendingPrivacy?.remoteConfirmed, false)
        RecoveryURLProtocol.handler = { $0.respond() }; await app.retryPrivacy()
        XCTAssertNil(app.pendingPrivacy); XCTAssertFalse(app.onboarded); XCTAssertEqual(app.api?.userID, "")
    }
    func testPushDeadlineCompletesOnceEvenIfWorkIgnoresCancellation() async throws {
        let completed = expectation(description: "Bounded push completion")
        var continuation: CheckedContinuation<Bool, Never>?, calls = 0, expired = false
        let start = ContinuousClock.now
        BackgroundSyncSlice.run(budget: .milliseconds(30), work: { await withCheckedContinuation { continuation = $0 } }, expired: { expired = true }, completion: { success in
            calls += 1; XCTAssertFalse(success); completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(expired); XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        continuation?.resume(returning: true); try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, 1)
    }
}

private actor CoalescingReader: HealthSyncReading {
    var page = 0
    var reads: [String: Int] = [:]
    let day = Date(timeIntervalSince1970: 1_500_000_000)
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) -> HealthPage {
        page += 1
        let definition = definitions[0]
        let sample = IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: definition.sampleType!.identifier, series: definition.id, period: HealthDates.day(day), start: day, end: day + 60)
        return HealthPage(samples: [sample], deleted: [], anchor: HKQueryAnchor(fromValue: page), readCount: 1000, hasMore: page < 10)
    }
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) -> PreparedChunk {
        reads[chunk.id, default: 0] += 1
        return PreparedChunk(data: Data("[]".utf8), count: page, first: HealthDates.day(day), last: HealthDates.day(day))
    }
    func readProfile() -> Data { Data("{}".utf8) }
    func recentRecords(definitions: [SeriesDefinition], now: Date) -> [IndexedSample] { [] }
}
private actor CoalescingUploader: SyncUploading {
    func upload(series: String, period: String, plaintext: Data, key: String) -> Int { plaintext.count }
    func delete(series: String, period: String) {}
    func updateCatalog(_ summary: UploadedSummary) {}
    func completeSync() {}
}
final class CoalescingSyncTests: XCTestCase {
    func testMissingLegacyUploadBecomesDurableRepairWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite")
        let chunk = DirtyChunk(series: "workouts", period: "2026-09-01/" + UUID().uuidString.lowercased())
        let old = try await SyncStore.open(url: url)
        try await old.recordUpload(chunk, count: 1, first: "2026-08-31", last: "2026-09-01")
        try await old.execute("DELETE FROM sync_metadata WHERE key='chunk-coverage-v1'")
        let migrated = try await SyncStore.open(url: url)
        let coverage = try await migrated.pendingCoverage()
        XCTAssertEqual(coverage.count, 1)
        XCTAssertEqual(coverage.first?.first, "2026-08-31")
        // The Worker reports that the old upload never reached its durable index.
        try await migrated.acknowledgeCoverage(coverage, missing: [chunk])
        let restarted = try await SyncStore.open(url: url)
        let remainingCoverage = try await restarted.pendingCoverage()
        let pending = try await restarted.nextDirty(limit: 4)
        XCTAssertTrue(remainingCoverage.isEmpty)
        XCTAssertEqual(pending, [chunk], "Repair work must survive a quit after coverage acknowledgement")
        try await restarted.recordUpload(chunk, count: 1, first: "2026-08-31", last: "2026-09-01")
        let repaired = try await restarted.nextDirty(limit: 4)
        XCTAssertTrue(repaired.isEmpty)
    }
    func testTenPagesReadEachPeriodAtMostTwiceAndKeepFinalUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite")), reader = CoalescingReader()
        let heart = SeriesDefinition.quantities.first { $0.id == "heart_rate" }!
        let result = await SyncEngine(store: store, reader: reader, client: CoalescingUploader(), key: "synthetic", run: SyncRun(trigger: "Test")) { _ in }.sync(definitions: [heart])
        let reads = await reader.reads, day = reader.day, period = HealthDates.day(day)
        XCTAssertEqual(result.status, "complete"); XCTAssertEqual(reads["heart_rate/" + period], 2)
        XCTAssertNil(reads["daily_summary/" + HealthDates.month(day)]); XCTAssertNil(reads["activity_rings/" + HealthDates.month(day)])
        let uploaded = try await store.rows("SELECT count FROM uploaded WHERE series='heart_rate' AND period=?", [period])
        XCTAssertEqual(uploaded.first?["count"] as? Int, 10, "The final scan must include changes after the early snapshot")
    }
    func testDeferredDirtyChunkSurvivesReopenAndNextRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite"), chunk = DirtyChunk(series: "heart_rate", period: "2026-09-01")
        let first = try await SyncStore.open(url: url)
        try await first.recordUpload(chunk, count: 2, first: chunk.period, last: chunk.period, runID: "interrupted")
        try await first.markDirty(chunk.series, chunk.period)
        let deferred = try await first.nextDirty(limit: 4, notUploadedInRun: "interrupted"); XCTAssertTrue(deferred.isEmpty)
        let reopened = try await SyncStore.open(url: url), pending = try await reopened.nextDirty(limit: 4, notUploadedInRun: "resumed")
        XCTAssertEqual(pending, [chunk])
    }
    func testOldWorkoutIsInvalidatedByLateHeartRateRouteAndRouteDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite")), start = Date(timeIntervalSince1970: 1_500_000_000)
        let workout = IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: "workout", series: "workouts", period: "2017-07-14/workout", start: start, end: start + 3600)
        try await store.applyPage(type: "workout", samples: [workout], deleted: [], anchor: nil)
        for series in ["heart_rate", "_workout_routes"] {
            try await store.execute("DELETE FROM dirty")
            let id = UUID(), sample = IndexedSample(uuid: id.uuidString.lowercased(), hkType: series, series: series, period: "2017-07-14/route", start: start + 30, end: start + 300)
            try await store.applyPage(type: series, samples: [sample], deleted: [], anchor: nil)
            var dirty = try await store.dirtyChunks(); XCTAssertTrue(dirty.contains(DirtyChunk(series: "workouts", period: workout.period)))
            XCTAssertFalse(dirty.contains { $0.series == "_workout_routes" })
            try await store.execute("DELETE FROM dirty")
            try await store.applyPage(type: series, samples: [], deleted: [id], anchor: nil)
            dirty = try await store.dirtyChunks(); XCTAssertTrue(dirty.contains(DirtyChunk(series: "workouts", period: workout.period)))
        }
    }
}
