# Upload latency and build 16 — September 10, 2026

## Diagnosis

The payload size was misleading: each small encrypted period still required a separate signed HTTP request, 11 serial D1 binding calls for a new object (13 for a replacement), an R2 write, and often an R2 deletion. The app used four concurrent uploads and stopped between upload batches to publish series summaries sequentially.

Before optimization, a production workload of 24 approximately 4 KB synthetic chunks measured 0.90 seconds per new upload and 1.02 seconds per replacement. A later instrumented run of the same code measured 1.58 and 2.33 seconds respectively. In that latter run, new uploads spent 591 ms waiting for D1 and 929 ms waiting for R2; replacements spent 684 ms in D1 and 1,591 ms in R2. Empty deletes, carrying no payload, still took 485 ms. Storage and request overhead dominate these measurements; they do not establish a Cloudflare incident or isolate why storage latency varied during the session.

The production bucket is in Western North America with Standard storage. No region migration or weaker durability setting is involved in this fix.

## Changes

- Batch device rate-limit accounting and the replay-nonce claim into one D1 transaction after signature verification. Batch upload admission, privacy-fence validation and the previous-object lookup. Include the successful-upload timestamp in the existing publication transaction. New uploads now need five D1 round trips instead of eleven.
- Acknowledge a replacement once its new object and index are durable. Delete the obsolete physical object through `waitUntil`, backed by the existing durable garbage collector. Old bytes continue counting against quota until deletion completes. Privacy fencing, compare-and-swap publication, and ambiguous-commit recovery remain enforced.
- Raise the app's bounded upload concurrency from four to eight. A per-sync sliding-window pacer permits eight request starts per second, including empty deletes and retries, keeping sustained traffic below the 600-writes-per-minute server limit.
- Publish up to four independent series summaries concurrently. Successful entries are individually acknowledged; failed or cancelled entries remain in the local outbox. Coverage is confirmed only after publication succeeds.
- Add developer-launch-only phone timing aggregates for HealthKit chunk preparation, compression/encryption, signing, request waits, server D1/R2 waits, and local acknowledgement. The opt-in response header and local diagnostic file contain no health values, keys, credentials, object names or SQL.

Fresh-data checks still preempt history at batch boundaries. Uploads remain bounded in memory, and pausing cancels the upload budget wait as well as HealthKit/network work.

## Production benchmark

Each row uses 24 synthetic requests per workload, the same approximate payload size, and a disposable signed account deleted afterward. These are measurements from a Mac against production, not an estimate of full HealthKit backfill speed. The eight-request comparison is an unpaced short burst; the app additionally caps sustained starts.

| Workload | Original, 4 concurrent | Optimized server, 4 concurrent | Optimized server, 8 concurrent |
| --- | ---: | ---: | ---: |
| New objects | 2.36 requests/s | 2.80 requests/s | 4.81 requests/s |
| Replacements | 1.65 requests/s | 2.92 requests/s | 5.38 requests/s |
| Empty deletes | 7.75 requests/s | 10.83 requests/s | 17.77 requests/s |
| D1 wait per new upload | 591 ms | 276 ms | 312 ms |
| R2 wait per new upload | 929 ms | 998 ms | 1,021 ms |

In the Mac benchmark, the remaining per-object delay is primarily the R2 write; additional concurrency overlaps that wait. A separate earlier baseline was faster than the instrumented baseline, so these ratios are session measurements, not guaranteed speedups across networks or days. One early timing-probe batch encountered a 500 response; it was not included in the completed workload comparison, and its temporary account was cleaned up. The subsequent complete benchmark runs and the production end-to-end suite passed.

Cloudflare documents that [D1 batches reduce network round trips](https://developers.cloudflare.com/d1/worker-api/d1-database/). The timings above are measured binding waits, including network time, rather than SQLite execution times.

## Connected iPhone measurement

Build 16 processed 486 chunks in the first 95 seconds after launch. In the next measured 83 seconds, it processed another 400 chunks and uploaded 1,348,131 encrypted bytes: **4.82 chunks/second**, with no sync errors. The earlier build-15 observation was 304 chunks in 180 seconds, or 1.69/second. This is an observed 2.85× improvement, but the two intervals cover different periods/types in the same ongoing backfill rather than replaying identical private health data.

The second phone snapshot contained 886 processed chunks, 51,000 newly indexed samples, and a recent-data checkpoint of 10:37:07 AM local time. Its measured average durations were:

| Operation | Mean |
| --- | ---: |
| HealthKit chunk query/preparation, including actor wait | 319 ms |
| Compression and encryption | 0.55 ms |
| Device signing | 10.3 ms |
| Upload request | 541 ms |
| Server D1 binding wait within upload | 288 ms |
| Server R2 binding wait within upload | 171 ms |
| Local upload acknowledgement | 1.29 ms |
| Request pacing wait | 15 ms |

The phone's R2 latency was much lower than the Mac benchmark's. On the phone, both database round trips and HealthKit preparation remain material; encryption is negligible. Durations overlap across concurrent tasks and must not be added as if they were total wall-clock runtime. Large historical backfills still require many period reads and durable object writes.

At 10:42:48 AM, the final phone snapshot showed 1,852 processed chunks, 151,000 indexed samples, 4,735,692 encrypted bytes uploaded and no errors. The five-minute fresh-data pass advanced the recent checkpoint to 10:42:18 AM before history resumed. This confirms the higher concurrency preserved live-data priority on the device.

## Validation and delivery

- TypeScript type checking; 33 Worker/protocol tests, including quota enforcement, replay rejection, privacy/reset races, lost commits, asynchronous cleanup and cleanup failure recovery.
- 21 local and 21 production end-to-end checks: signed device requests, OAuth pairing, official MCP SDK discovery, authenticated download/decryption, deletion propagation, revocation, rotation and fixture cleanup.
- 55 native iOS tests on iOS 26.3, including freshness ordering, persisted catch-up windows, incremental indexing, catalog concurrency/failure/restart, request pacing and cancellation.
- Worker version `0ea64727-fa3d-4997-bb5f-f8ba99fe6c1f` deployed to `mcp.healthmcp.cc`.
- Signed Release build `1.0.0 (16)` installed on the connected iPhone 17 Pro without resetting its cache or keys. Device IPA SHA-256: `dcdc2165d7302facd8ff3becc2dfd9bbd2f4d43df5c93525ad1a384695a24bbb`.

Raw operational evidence and build outputs are excluded from Git under `artifacts/upload-performance-2026-09-10/`. App Review remains on the previously submitted build 14.
