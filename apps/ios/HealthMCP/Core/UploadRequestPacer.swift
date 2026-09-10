import Foundation

actor UploadRequestPacer {
    private let maximum: Int
    private let interval: Duration
    private var starts: [ContinuousClock.Instant] = []
    init(maximum: Int = 8, interval: Duration = .seconds(1)) {
        precondition(maximum > 0 && interval > .zero)
        self.maximum = maximum; self.interval = interval
    }
    // Allow a full parallel batch immediately, but cap sustained traffic below
    // the service's 600 writes/minute budget (including retries and deletes).
    func wait() async throws {
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            starts.removeAll { $0.advanced(by: interval) <= now }
            if starts.count < maximum { starts.append(now); return }
            try await Task.sleep(until: starts[0].advanced(by: interval), clock: .continuous)
        }
    }
}
