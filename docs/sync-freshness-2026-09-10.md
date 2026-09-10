# Newest-data priority — build 15

A resumed recent scan retained yesterday's fixed HealthKit predicate. After completing it, the engine proceeded into historical indexing even though its freshness checkpoint was hours old. Returning to the foreground while that run remained active did not request a fresh pass. The UI also replaced the partial uploaded span with the narrower confirmed range, making preserved history appear to disappear.

## Changes

- Durable catch-up windows run ahead of the original recent scan, coverage migration, historical enumeration, and historical uploads. A newer window preempts an unfinished older one without changing the older window's predicate or losing its record cursor.
- Returning to the app or receiving a HealthKit notification requests fresh data at the next safe page/batch boundary. Long runs also check every five minutes. Repeated requests within a minute of the current target are coalesced.
- Only the buckets covering the missed recent interval are reread. The original backfill retains its anchors and pending work. Acknowledging a full bucket also satisfies older catch-up windows waiting for that same bucket.
- Confirmed freshness advances after record enumeration, all required uploads/deletions, and catalog publication succeed. An old checkpoint or the original run-start timestamp cannot move freshness backward. Failed fresh publication prevents historical work from continuing.
- The ready card retains the partial uploaded history span alongside complete coverage. During a catch-up pass, it explicitly says that newest data is being updated first.
- Privacy cleanup clears the additional windows, pending work, and cursors. The journal still stores operational metadata and identifiers, not health values.
- A developer launch with `-sync-diagnostics` permits local operational progress inspection in Release builds. It includes timestamps/counts/status, excludes health values and credentials, is excluded from backup, and is never uploaded. Ordinary Release launches do not write this diagnostic file.

## Background diagnosis

The connected build 13's journal contained an early-morning background attempt that uploaded 12 chunks before the existing 23-second budget, followed by an attempt paused because HealthKit was inaccessible while locked. The visible freshness timestamp described the last completely checked recent window, not the last successful individual upload. The inspected morning foreground run still carried the previous evening's checkpoint.

HealthKit reads can be unavailable while the phone is locked. iOS also decides when a scheduled background task runs; the requested 2 AM time is an earliest start, not a guarantee. These platform limits remain applicable. References: [HealthKit privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy), [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate).

## Validation

- iPhone 17 Pro / iOS 26.3: all 50 native tests passed, including six new freshness regressions. Three affected UI tests passed with normal simulator signing.
- iPhone SE / iOS 18.1: all 21 freshness/availability tests and the new catch-up UI test passed.
- Regressions cover a 15-hour interrupted checkpoint, newest-window priority, durable record-cursor resumption, foreground preemption, five-minute refresh during backfill, failed catalog publication, monotonic timestamps, and privacy cleanup.
- The new card was visually inspected on the simulator. An initial unsigned UI-test attempt could not access Keychain; rerunning with simulator signing resolved the test setup issue.
- Release archive and ad hoc export succeeded for 1.0.0 (15); signature verification passed. Export used the existing ASC API credential after the cached Xcode account session failed.
- Physical installation and fresh-data verification are pending reconnection: the iPhone became unavailable before installation.
- Build 14 remains the submitted App Review build. Build 15 has not been uploaded or substituted into that submission.

Local evidence: `artifacts/device-sync-diagnosis-2026-09-10/`, `artifacts/fresh-priority-final-tests.xcresult`, `artifacts/fresh-priority-ui-tests.xcresult`, `artifacts/fresh-priority-ios18-tests.xcresult`.

Ad hoc IPA SHA-256: `009f3ed8b5507a2ded0e7398908ab4c6e6d9c1846676f185a907285b9e2f09c7`.
