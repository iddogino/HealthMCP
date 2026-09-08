# Incremental sync: September 8, 2026

Build 4 addresses the overnight backfill stall and unresponsive UI reported on the owner's iPhone 17 Pro. The first implementation enumerated all HealthKit types before starting health-data uploads. HealthKit result conversion, SQLite indexing, and chunk serialization also shared the main actor with SwiftUI.

## Diagnosis

The device's operational journal contained 835,846 indexed sample identifiers, 7,355 pending chunks, and only nine committed type anchors. The active run had scanned 122,019 samples without uploading a health chunk. A preceding run paused when HealthKit became protected after device lock. These are journal counters; no health values were exported for diagnosis.

Source inspection confirmed the global enumeration barrier and main-actor work. Instruments did not attach successfully, so this report does not assign a measured fraction of the old runtime to individual CPU functions.

## Implementation

- `SyncEngine`, `HealthReader`, and `SyncStore` use background actors. SwiftUI receives throttled progress snapshots. HealthKit query execution and cancellation are dispatched off the UI thread.
- Seed recent daily periods, current monthly periods, and recent workout/ECG records before scanning history. Publish an initial upload batch and its catalog immediately.
- Read one page of at most 1,000 anchored records, atomically commit the anchor and pending periods, then process up to four chunks concurrently. Rotate among types, prioritizing common activity data. Continue publishing available series during enumeration.
- Reuse prepared SQLite statements and deduplicate dirty periods within each transaction. Preserve existing keys, anchors, indexed identifiers, pending uploads, and history during migration.
- Acknowledge uploaded chunks and pending catalog publication in one local transaction. If the app closes before catalog publication, replay it on the next run, including deletions.
- Bound upload concurrency and retries. HealthKit queries time out after 90 seconds, cancellation stops queries without blocking the UI, and protected-data errors pause with progress retained.
- Show live uploaded bytes, processed chunks, scanned data types, a progress bar, pause/resume, and history. The total may grow as historical periods are discovered; it is not a time estimate.

The completed-sync timestamp still means all selected types and pending work finished. Individual uploaded series are usable before that timestamp exists. The first export still requires reading the user's complete shared history; later anchored queries request changes since saved checkpoints. iOS can pause protected HealthKit access when the phone locks.

## Validation

Nineteen distinct native tests passed across the full suite and targeted reruns after the final changes. New integration tests exercise the actual sync engine with a real SQLite journal: upload/catalog publication before enumeration finishes, interleaving between pages, protected-data pause, prompt cancellation, legacy migration, and replaying a catalog update after restart.

| Measurement | Observed result |
|---|---|
| Synthetic SQLite indexing, five 1,000-record pages | Mean decreased from 24.1 ms to 11.4 ms |
| 100,000-record simulator stress test | 366 main-actor heartbeat ticks; maximum gap 11.1 ms with a 10 ms timer |
| Physical device while syncing and performing MCP validation | Maximum heartbeat gap 71.4 ms with a 50 ms timer |
| Device snapshot after approximately 156 seconds | 70,365 newly scanned samples, 420 processed chunks, 819,128 encrypted bytes uploaded, 33/53 types exhausted, zero sync errors |
| Official MCP SDK before the first completed sync | 42 available series; global `last_synced_at` still null |
| Real HealthKit round trip | OAuth pairing, MCP discovery, key-check decryption, downloaded health data matching a fresh HealthKit read on the phone, and invalid-AAD rejection all passed |
| Real APNs request | Accepted at 17:08:11 UTC; iPhone delegate receipt recorded at 17:08:12 UTC |

Processed chunks include empty-period deletions, not only uploads. Indexing benchmarks are controlled fixtures, not an estimate of total backfill speed. Heartbeat gaps measure main-actor scheduling, not animation frame times. The physical push check ran with the app open; it does not establish background completion or force-quit fallback behavior.

Redacted counters and checks are saved in `docs/evidence/sync-performance.json` and `device-roundtrip.json`. Raw operational artifacts, the temporary OAuth session, and signing outputs are excluded from Git. The private health key and plaintext remained on the phone.
