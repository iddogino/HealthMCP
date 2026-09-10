import Foundation

enum CatalogPublisher {
    // Upload batches have finished before this runs. Each series is independent;
    // acknowledge it only after its server PUT succeeds. Failed/cancelled work
    // remains in the durable outbox for the next sync.
    static func flush(store: SyncStore, client: any SyncUploading) async throws {
        let series = try await store.pendingCatalog()
        var remaining = series.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueue(_ series: String) {
                group.addTask(priority: .utility) {
                    try Task.checkCancellation()
                    let summary = try await store.uploadedSummary(series)
                    try await client.updateCatalog(summary)
                    try await store.acknowledgeCatalog(series)
                }
            }
            for _ in 0..<4 { if let next = remaining.next() { enqueue(next) } }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let next = remaining.next() { enqueue(next) }
            }
        }
    }
}
