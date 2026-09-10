import Foundation

// Developer-launch diagnostics only. Aggregate operational durations, never
// health values, URLs, series names, credentials or encryption keys.
actor SyncPerformance {
    static let shared = SyncPerformance()
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-sync-diagnostics") }
    private struct Metric {
        var count = 0
        var total = 0.0
        var maximum = 0.0
        var recent: [Double] = []
        mutating func add(_ value: Double) {
            count += 1; total += value; maximum = max(maximum, value)
            if recent.count == 128 { recent.removeFirst() }
            recent.append(value)
        }
    }
    private var metrics: [String: Metric] = [:]
    func reset() { metrics.removeAll() }
    func record(_ name: String, milliseconds: Double) {
        guard Self.enabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        metrics[name, default: Metric()].add(milliseconds)
    }
    func record(_ name: String, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now).components
        record(name, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    func snapshot() -> [String: [String: Double]] {
        metrics.mapValues { value in
            let sorted = value.recent.sorted()
            return ["count": Double(value.count), "mean_ms": value.total / Double(value.count), "max_ms": value.maximum, "recent_p50_ms": sorted[sorted.count / 2], "recent_p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
        }
    }
}
