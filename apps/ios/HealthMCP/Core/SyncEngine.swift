import Foundation
import HealthKit

struct HealthPage: @unchecked Sendable {
    let samples: [IndexedSample]
    let deleted: [UUID]
    let anchor: HKQueryAnchor?
    let readCount: Int
    let hasMore: Bool
}
struct PreparedChunk: Sendable { let data: Data, count: Int, first: String, last: String }
protocol HealthSyncReading: Sendable {
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) async throws -> HealthPage
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) async throws -> PreparedChunk
    func readProfile() async throws -> Data
    func recentRecords(definitions: [SeriesDefinition], now: Date) async throws -> [IndexedSample]
}
protocol SyncUploading: Sendable {
    func upload(series: String, period: String, plaintext: Data, key: String) async throws -> Int
    func upload(series: String, period: String, plaintext: Data, key: String, coverage: ChunkCoverage?) async throws -> Int
    func updateCoverage(_ coverage: [ChunkCoverage]) async throws -> [DirtyChunk]
    func delete(series: String, period: String) async throws
    func updateCatalog(_ summary: UploadedSummary) async throws
    func completeSync() async throws
}

extension SyncUploading {
    func upload(series: String, period: String, plaintext: Data, key: String, coverage: ChunkCoverage?) async throws -> Int { try await upload(series: series, period: period, plaintext: plaintext, key: key) }
    func updateCoverage(_ coverage: [ChunkCoverage]) async throws -> [DirtyChunk] { [] }
}

enum BackfillPlan {
    static func recentChunks(definitions: [SeriesDefinition], now: Date) -> [DirtyChunk] {
        var chunks: Set<DirtyChunk> = [DirtyChunk(series: "daily_summary", period: HealthDates.month(now)), DirtyChunk(series: "activity_rings", period: HealthDates.month(now))]
        for definition in definitions where definition.chunk != "record" {
            for offset in 0..<(definition.chunk == "month" ? 1 : 7) {
                let day = now.addingTimeInterval(-Double(offset) * 86400)
                chunks.insert(DirtyChunk(series: definition.id, period: definition.chunk == "month" ? HealthDates.month(day) : HealthDates.day(day)))
            }
        }
        return chunks.sorted { $0.id < $1.id }
    }
}

// No UI work runs here. Each turn commits one HealthKit page, then drains a
// bounded upload batch. There is never an unbounded producer queue in memory.
actor SyncEngine {
    private let store: SyncStore
    private let reader: any HealthSyncReading
    private let client: any SyncUploading
    private let key: String
    private var run: SyncRun
    private var failedChunks = Set<String>()
    private var lastUIUpdate = ContinuousClock.now
    private var lastSave = ContinuousClock.now
    private var lastCatalogUpdate = ContinuousClock.now
    private let progress: @MainActor @Sendable (SyncRun) -> Void
    init(store: SyncStore, reader: any HealthSyncReading, client: any SyncUploading, key: String, run: SyncRun, progress: @escaping @MainActor @Sendable (SyncRun) -> Void) {
        self.store = store; self.reader = reader; self.client = client; self.key = key; self.run = run; self.progress = progress
    }
    func sync(definitions: [SeriesDefinition], now: Date = Date()) async -> SyncRun {
        let grouped = Dictionary(grouping: definitions.filter { $0.sampleType != nil }, by: { $0.sampleType!.identifier })
        let priority = ["StepCount", "HeartRate", "SleepAnalysis", "ActiveEnergyBurned"]
        var queue = grouped.keys.sorted()
        queue.sort { lhs, rhs in
            let l = priority.firstIndex(of: grouped[lhs]!.first!.hkName) ?? 100
            let r = priority.firstIndex(of: grouped[rhs]!.first!.hkName) ?? 100
            return l == r ? lhs < rhs : l < r
        }
        run.phase = "streaming"; run.totalTypes = queue.count; run.completedTypes = 0
        do {
            try Task.checkCancellation()
            try await publish(force: true)
            run.stage = "Preparing recent data"
            _ = try await client.upload(series: "check", period: "single", plaintext: Data("\"ok\"".utf8), key: key)
            try await flushCoverage()
            try await store.seedRecent(BackfillPlan.recentChunks(definitions: definitions, now: now), day: HealthDates.day(now))
            try await store.markDirty("daily_summary", HealthDates.month(now), priority: 200)
            try await store.markDirty("activity_rings", HealthDates.month(now), priority: 200)
            let profile = try await reader.readProfile()
            run.uploadedBytes += try await client.upload(series: "profile", period: "single", plaintext: profile, key: key)
            try await store.recordUpload(DirtyChunk(series: "profile", period: "single"), count: 1, first: HealthDates.day(now), last: HealthDates.day(now))
            for sample in try await reader.recentRecords(definitions: definitions, now: now) {
                try await store.applyPage(type: sample.hkType, samples: [sample], deleted: [], anchor: nil)
                try await store.markDirty(sample.series, sample.period, priority: 150)
            }
            _ = try await drainBatch(definitions: definitions)
            try await flushCatalog(force: true)
            while !queue.isEmpty {
                try Task.checkCancellation()
                let type = queue.removeFirst(), entries = grouped[type]!
                run.stage = "Reading \(entries[0].title) · uploads continue between pages"
                try await publish(force: true)
                do {
                    let anchor = try await store.anchor(for: type)
                    let readStart = ContinuousClock.now
                    let page = try await reader.readPage(definitions: entries, anchor: anchor)
                    run.maxReadMS = max(run.maxReadMS ?? 0, Self.milliseconds(since: readStart))
                    try Task.checkCancellation()
                    let indexStart = ContinuousClock.now
                    try await store.applyPage(type: type, samples: page.samples, deleted: page.deleted, anchor: page.anchor)
                    run.maxIndexMS = max(run.maxIndexMS ?? 0, Self.milliseconds(since: indexStart))
                    run.sampleCount += page.readCount
                    if page.hasMore { queue.append(type) }
                    else { run.completedTypes = (run.completedTypes ?? 0) + 1 }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if SyncInterruption.isHealthDataLocked(error) { throw error }
                    addError("\(entries[0].title): \(error.localizedDescription)")
                    run.completedTypes = (run.completedTypes ?? 0) + 1
                }
                _ = try await drainBatch(definitions: definitions)
                try await flushCatalog()
                run.progress = 0.6 * Double(run.completedTypes ?? 0) / Double(max(1, run.totalTypes ?? 1))
                try await publish()
                if run.errors.count >= 20 { throw HealthMCPError.message("Several items need another attempt. Remaining work is saved.") }
            }
            run.phase = "uploading"
            while try await drainBatch(definitions: definitions) {
                try Task.checkCancellation()
                try await flushCatalog()
                let pending = try await store.dirtyCount()
                run.progress = 0.6 + 0.4 * Double(run.uploadedChunks) / Double(max(1, run.uploadedChunks + pending))
                try await publish()
                if run.errors.count >= 20 { break }
            }
            try await flushCatalog(force: true)
            if run.errors.isEmpty, try await store.dirtyCount() == 0 {
                try await client.completeSync()
                run.status = "complete"; run.progress = 1; run.stage = "Your encrypted cache is up to date"
            } else { run.status = "partial"; run.stage = "Some data needs another attempt. Completed uploads are available to your agents." }
        } catch where SyncInterruption.isHealthDataLocked(error) { run.pauseForProtectedData() }
        catch is CancellationError { run.status = "paused"; run.stage = "Progress saved. Completed uploads are available to your agents." }
        catch {
            if Task.isCancelled { run.status = "paused"; run.stage = "Progress saved. Completed uploads are available to your agents." }
            else { run.status = "failed"; run.stage = "Sync needs attention. Your progress is saved."; addError(error.localizedDescription) }
        }
        run.finishedAt = Date()
        try? await publish(force: true)
        return run
    }
    private func drainBatch(definitions: [SeriesDefinition]) async throws -> Bool {
        try Task.checkCancellation()
        let chunks = try await store.nextDirty(limit: 4, excluding: failedChunks, notUploadedInRun: run.phase == "streaming" ? run.id : nil)
        guard !chunks.isEmpty else { return false }
        run.stage = "Encrypting and uploading \(chunks.first!.series.replacingOccurrences(of: "_", with: " "))"
        try await publish()
        let reader = reader, client = client, key = key, store = store, runID = run.id
        var locked = false
        await withTaskGroup(of: (DirtyChunk, Int, Double, String?, Bool).self) { group in
            for chunk in chunks {
                group.addTask(priority: .utility) {
                    let start = ContinuousClock.now
                    do {
                        let payload = try await reader.readChunk(chunk, definitions: definitions)
                        try Task.checkCancellation()
                        var bytes = 0
                        for attempt in 0..<3 {
                            do {
                                if payload.count == 0 { try await client.delete(series: chunk.series, period: chunk.period) }
                                else { bytes = try await client.upload(series: chunk.series, period: chunk.period, plaintext: payload.data, key: key, coverage: ChunkCoverage(series: chunk.series, period: chunk.period, first: payload.first, last: payload.last)) }
                                break
                            } catch {
                                if attempt == 2 || Task.isCancelled || (error as? APIError)?.isRetryable == false { throw error }
                                let delay = min(60, max(Double(1 << attempt), (error as? APIError)?.retryAfter ?? 0))
                                try await Task.sleep(for: .seconds(delay))
                            }
                        }
                        try await store.recordUpload(chunk, count: payload.count, first: payload.first, last: payload.last, runID: runID)
                        return (chunk, bytes, Self.milliseconds(since: start), nil, false)
                    } catch {
                        return (chunk, -1, Self.milliseconds(since: start), error is CancellationError || Task.isCancelled ? nil : error.localizedDescription, SyncInterruption.isHealthDataLocked(error))
                    }
                }
            }
            for await (chunk, bytes, milliseconds, error, isLocked) in group {
                run.maxChunkMS = max(run.maxChunkMS ?? 0, milliseconds)
                if isLocked { locked = true; group.cancelAll() }
                else if bytes >= 0 { run.uploadedChunks += 1; run.uploadedBytes += bytes }
                else if let error { failedChunks.insert(chunk.id); addError("\(chunk.series): \(error)") }
                try? await publish()
            }
        }
        if locked { throw SyncInterruption.healthDataLocked }
        try Task.checkCancellation()
        return true
    }
    private func flushCoverage() async throws {
        while true {
            try Task.checkCancellation()
            let batch = try await store.pendingCoverage()
            guard !batch.isEmpty else { return }
            let missing = try await client.updateCoverage(batch)
            try await store.acknowledgeCoverage(batch, missing: missing)
        }
    }
    private func flushCatalog(force: Bool = false) async throws {
        guard force || lastCatalogUpdate.duration(to: .now) >= .seconds(3) else { return }
        for series in try await store.pendingCatalog() {
            let summary = try await store.uploadedSummary(series)
            try await client.updateCatalog(summary)
            try await store.acknowledgeCatalog(series)
        }
        lastCatalogUpdate = .now
    }
    private func publish(force: Bool = false) async throws {
        run.totalChunks = run.uploadedChunks + (try await store.dirtyCount())
        if force || lastSave.duration(to: .now) >= .seconds(1) {
            try await store.save(run); lastSave = .now
            #if DEBUG
            SyncDiagnostics.progress(run)
            #endif
        }
        if force || lastUIUpdate.duration(to: .now) >= .milliseconds(250) { await progress(run); lastUIUpdate = .now }
    }
    private func addError(_ message: String) { if run.errors.count < 20, !run.errors.contains(message) { run.errors.append(message) } }
    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Double { let elapsed = start.duration(to: .now).components; return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15 }
}

extension APIClient: SyncUploading {
    func updateCoverage(_ coverage: [ChunkCoverage]) async throws -> [DirtyChunk] {
        let result = try await json("PUT", "/v1/chunk-coverage", ["chunks": coverage.map { ["series": $0.series, "period": $0.period, "first_day": $0.first, "last_day": $0.last] }])
        return (result["missing"] as? [[String: String]] ?? []).compactMap { row in
            guard let series = row["series"], let period = row["period"], coverage.contains(where: { $0.series == series && $0.period == period }) else { return nil }
            return DirtyChunk(series: series, period: period)
        }
    }
    func updateCatalog(_ summary: UploadedSummary) async throws { _ = try await json("PUT", "/v1/series", ["series": summary.series, "first_day": summary.first, "last_day": summary.last, "total_samples": summary.count]) }
    func completeSync() async throws { _ = try await json("POST", "/v1/sync/complete", [:]) }
}

extension HealthReader: HealthSyncReading {
    func readPage(definitions: [SeriesDefinition], anchor: HKQueryAnchor?) async throws -> HealthPage {
        guard let type = definitions.first?.sampleType else { throw HealthMCPError.message("Unknown Health type.") }
        let (samples, deleted, next) = try await anchored(type: type, anchor: anchor)
        let hasMore = samples.count + deleted.count >= 1000
        if hasMore {
            guard let next else { throw HealthMCPError.message("Apple Health did not return a progress anchor.") }
            if let anchor, try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) == NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true) { throw HealthMCPError.message("Apple Health did not advance its progress anchor. Try resuming sync.") }
        }
        return HealthPage(samples: definitions.flatMap { definition in samples.map { index($0, definition: definition) } }, deleted: deleted.map(\.uuid), anchor: next, readCount: samples.count, hasMore: hasMore)
    }
    func readProfile() throws -> Data { try json(profile()) }
    func readChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) async throws -> PreparedChunk {
        let (data, count) = try await self.chunk(chunk, definitions: definitions)
        let object = try JSONSerialization.jsonObject(with: data)
        let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        let days = rows.flatMap { row in ["t", "t0", "t1", "d"].compactMap { (row[$0] as? String).map { String($0.prefix(10)) } } }
        let fallback = String(chunk.period.prefix(10))
        return PreparedChunk(data: data, count: count, first: days.min() ?? fallback, last: days.max() ?? fallback)
    }
    func recentRecords(definitions: [SeriesDefinition], now: Date) async throws -> [IndexedSample] {
        var result: [IndexedSample] = []
        for definition in definitions where definition.chunk == "record" && definition.kind != .route {
            guard let type = definition.sampleType else { continue }
            let samples = try await samples(type: type, predicate: HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-7 * 86400), end: now), limit: 8, ascending: false)
            result.append(contentsOf: samples.map { index($0, definition: definition) })
        }
        return result
    }
}
