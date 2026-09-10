import XCTest
@testable import HealthMCP

final class UploadRequestPacerTests: XCTestCase {
    func testParallelBurstIsAllowedButNextBurstWaitsForBudget() async throws {
        let pacer = UploadRequestPacer(maximum: 4, interval: .milliseconds(200))
        let times = try await withThrowingTaskGroup(of: ContinuousClock.Instant.self) { group in
            for _ in 0..<12 { group.addTask { try await pacer.wait(); return .now } }
            var times: [ContinuousClock.Instant] = []
            for try await time in group { times.append(time) }
            return times.sorted()
        }
        XCTAssertLessThan(times[0].duration(to: times[3]), .milliseconds(100))
        XCTAssertGreaterThanOrEqual(times[0].duration(to: times[4]), .milliseconds(190))
        XCTAssertGreaterThanOrEqual(times[0].duration(to: times[8]), .milliseconds(390))
    }
    func testWaitingForBudgetIsPromptlyCancellable() async throws {
        let pacer = UploadRequestPacer(maximum: 1, interval: .seconds(60))
        try await pacer.wait()
        let task = Task { try await pacer.wait() }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now; task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
}
