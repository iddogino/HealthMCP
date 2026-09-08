import XCTest
import HealthKit
@testable import HealthMCP

final class SyncPerformanceTests: XCTestCase {
    @MainActor func testLargeJournalLeavesMainActorResponsive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("large.sqlite"))
        let storeOnMain = await store.executorIsMainThread(), readerOnMain = await HealthReader().executorIsMainThread()
        XCTAssertFalse(storeOnMain); XCTAssertFalse(readerOnMain)
        var largestGap = 0.0, ticks = 0
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = ContinuousClock.now, gap = previous.duration(to: now).components
                largestGap = max(largestGap, Double(gap.seconds) * 1000 + Double(gap.attoseconds) / 1e15)
                previous = now; ticks += 1
            }
        }
        try await Task.detached(priority: .utility) {
            for page in 0..<100 {
                let samples = (0..<1000).map { offset in
                    let date = Date(timeIntervalSince1970: 1_780_000_000 + Double(page * 1000 + offset) * 60)
                    return IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: "benchmark", series: "active_energy", period: HealthDates.day(date), start: date, end: date + 60)
                }
                try await store.applyPage(type: "benchmark", samples: samples, deleted: [], anchor: HKQueryAnchor(fromValue: page + 1))
            }
        }.value
        heartbeat.cancel(); await heartbeat.value
        print("SYNC_UI_RESPONSIVENESS samples=100000 ticks=\(ticks) max_gap_ms=\(largestGap)")
        XCTAssertGreaterThan(ticks, 10); XCTAssertLessThan(largestGap, 200)
        let count = try await store.totalSamples(); XCTAssertEqual(count, 100000)
    }
    @MainActor func testPageIndexingBenchmark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("benchmark.sqlite"))
        var durations: [Double] = []
        for page in 0..<5 {
            let samples = (0..<1000).map { offset in
                let date = Date(timeIntervalSince1970: 1_780_000_000 + Double(page * 1000 + offset) * 60)
                return IndexedSample(uuid: UUID().uuidString.lowercased(), hkType: "benchmark", series: "active_energy", period: HealthDates.day(date), start: date, end: date + 60)
            }
            let start = ContinuousClock.now
            try await store.applyPage(type: "benchmark", samples: samples, deleted: [], anchor: HKQueryAnchor(fromValue: page + 1))
            durations.append(Double(start.duration(to: .now).components.attoseconds) / 1e15 + Double(start.duration(to: .now).components.seconds) * 1000)
        }
        print("SYNC_INDEX_BENCHMARK_MS \(durations)")
        let count = try await store.totalSamples(); XCTAssertEqual(count, 5000)
    }
}
extension SyncStore { func executorIsMainThread() -> Bool { Thread.isMainThread } }
extension HealthReader { func executorIsMainThread() -> Bool { Thread.isMainThread } }
