import Foundation
import HealthKit

// A query's callback, cancellation, and timeout compete to finish one continuation.
// Keeping that handoff synchronous also handles cancellation before execute().
private final class HealthQueryGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let execution = DispatchQueue(label: "cc.healthmcp.health-query", qos: .utility)
    private let store: HKHealthStore
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var query: HKQuery?
    private var timeout: DispatchWorkItem?
    init(store: HKHealthStore) { self.store = store }
    func start(_ continuation: CheckedContinuation<Value, Error>, make: (@escaping (Result<Value, Error>) -> Void) -> HKQuery) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        let query = make { [weak self] in self?.finish($0) }
        self.query = query
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(HealthMCPError.message("Apple Health took too long to respond. Progress is saved; try resuming sync."))) }
        self.timeout = timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: timeout)
        lock.unlock()
        execution.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let finished = self.result != nil; self.lock.unlock()
            if !finished { self.store.execute(query) }
        }
    }
    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation, query = query, timeout = timeout
        self.continuation = nil; self.query = nil; self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        if let query { execution.async { [store] in store.stop(query) } }
        continuation?.resume(with: value)
    }
}

func runHealthQuery<Value>(store: HKHealthStore, make: (@escaping (Result<Value, Error>) -> Void) -> HKQuery) async throws -> Value {
    let gate = HealthQueryGate<Value>(store: store)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { gate.start($0, make: make) }
    } onCancel: { gate.finish(.failure(CancellationError())) }
}
