#if DEBUG
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
        write(["updated_at": HealthDates.timestamp(Date()), "status": run.status, "phase": run.phase ?? "", "scanned_samples": run.sampleCount, "processed_chunks": run.uploadedChunks, "pending_chunks": run.totalChunks - run.uploadedChunks, "uploaded_bytes": run.uploadedBytes, "types_complete": run.completedTypes ?? 0, "types_total": run.totalTypes ?? 0, "max_read_ms": run.maxReadMS ?? 0, "max_index_ms": run.maxIndexMS ?? 0, "max_chunk_ms": run.maxChunkMS ?? 0, "errors": Array(run.errors.prefix(2))], name: "progress.json")
    }
}
#endif
