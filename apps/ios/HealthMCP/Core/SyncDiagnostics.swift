import Foundation

enum SyncDiagnostics {
    static func write(_ value: [String: Any], name: String) {
        do {
            var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Validation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try directory.setResourceValues(resources)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Diagnostics must never interrupt sync. */ }
    }
    static func progress(_ run: SyncRun) {
        #if !DEBUG
        // Developer-launch opt-in only. No health values or credentials are
        // included, and this local file is never uploaded or backed up.
        guard ProcessInfo.processInfo.arguments.contains("-sync-diagnostics") else { return }
        #endif
        var values: [String: Any] = ["updated_at": HealthDates.timestamp(Date()), "status": run.status, "phase": run.phase ?? "", "scanned_samples": run.sampleCount, "processed_chunks": run.uploadedChunks, "pending_chunks": run.totalChunks - run.uploadedChunks, "uploaded_bytes": run.uploadedBytes, "types_complete": run.completedTypes ?? 0, "types_total": run.totalTypes ?? 0, "max_read_ms": run.maxReadMS ?? 0, "max_index_ms": run.maxIndexMS ?? 0, "max_chunk_ms": run.maxChunkMS ?? 0, "errors": Array(run.errors.prefix(2))]
        if let availability = run.availability {
            values["confirmed_since"] = HealthDates.timestamp(availability.since)
            values["recent_data_checked_at"] = HealthDates.timestamp(availability.refreshedAt)
            values["history_complete"] = availability.historyComplete
        }
        write(values, name: "progress.json")
    }
}
