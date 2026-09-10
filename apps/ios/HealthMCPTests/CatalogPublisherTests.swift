import XCTest
@testable import HealthMCP

private actor CatalogTestClient: SyncUploading {
    var blocked: Bool
    var active = 0
    var maximum = 0
    var succeeded = Set<String>()
    let failing: String?
    init(blocked: Bool = false, failing: String? = nil) { self.blocked = blocked; self.failing = failing }
    func release() { blocked = false }
    func upload(series: String, period: String, plaintext: Data, key: String) -> Int { 0 }
    func delete(series: String, period: String) {}
    func completeSync() {}
    func updateCatalog(_ summary: UploadedSummary) async throws {
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        while blocked { try await Task.sleep(for: .milliseconds(5)) }
        if summary.series == failing { throw HealthMCPError.message("Synthetic catalog failure") }
        try Task.checkCancellation()
        succeeded.insert(summary.series)
    }
}

final class CatalogPublisherTests: XCTestCase {
    private func seededStore(_ directory: URL) async throws -> SyncStore {
        let store = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite"))
        for series in ["steps", "heart_rate", "sleep", "body_mass", "height", "hrv", "daily_summary", "activity_rings"] {
            try await store.recordUpload(DirtyChunk(series: series, period: "2026-09"), count: 1, first: "2026-09-01", last: "2026-09-01")
        }
        return store
    }
    func testIndependentSeriesPublishConcurrentlyWithFourRequestLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seededStore(directory), client = CatalogTestClient(blocked: true)
        let task = Task { try await CatalogPublisher.flush(store: store, client: client) }
        for _ in 0..<200 { if await client.active == 4 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let active = await client.active
        await client.release(); try await task.value
        XCTAssertEqual(active, 4)
        let maximum = await client.maximum, succeeded = await client.succeeded, pending = try await store.pendingCatalog()
        XCTAssertEqual(maximum, 4); XCTAssertEqual(succeeded.count, 8); XCTAssertTrue(pending.isEmpty)
    }
    func testFailedPublicationStaysPendingAndCanBeReplayedAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seededStore(directory), client = CatalogTestClient(failing: "height")
        do { try await CatalogPublisher.flush(store: store, client: client); XCTFail("Expected publication failure") } catch {}
        let pending = try await store.pendingCatalog()
        XCTAssertTrue(pending.contains("height"))
        let reopened = try await SyncStore.open(url: directory.appendingPathComponent("sync.sqlite"))
        try await CatalogPublisher.flush(store: reopened, client: CatalogTestClient())
        let remaining = try await reopened.pendingCatalog(); XCTAssertTrue(remaining.isEmpty)
    }
    func testCancellationRetainsUnacknowledgedCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seededStore(directory), client = CatalogTestClient(blocked: true)
        let task = Task { try await CatalogPublisher.flush(store: store, client: client) }
        for _ in 0..<200 { if await client.active > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let pending = try await store.pendingCatalog(); XCTAssertEqual(pending.count, 8)
    }
}
