# Sync availability and copy update — September 9, 2026

The Overview now leads with **Connect your agents to Apple Health** and, once coverage is confirmed, a **Ready for your agents** card. It shows **Synced all shared data since [date]**, **Last synced data [age]**, and a direct link to Agents. It explicitly tells users they can start using their agent while older history continues. The confirmed range stays visible when a sync pauses.

The Overview footer uses the requested encrypted-cloud-copy and background-refresh explanation. The Agents headline is **Connect your agent to HealthMCP**. The activity indicator no longer labels an unfinished scan “LIVE.”

## What the range means

- The first confirmed range covers today and the preceding six UTC dates, across the selected, readable data types. Monthly buckets cover both months when that window crosses a month boundary.
- Every recent bucket must be queried and acknowledged by the service, including empty buckets and deletions. Catalog publication must also succeed before the range appears.
- Recent workout and ECG enumeration now pages through all matching records in batches of up to 1,000, replacing the previous eight-record limit. Its predicate-specific cursors are separate from the full-history anchors.
- Pending recent buckets and record cursors are durable. An interrupted recent scan resumes the same window without repeating its acknowledged chunks. No health values are added to the journal.
- After all full-history HealthKit queries reach their anchors, the newest remaining gap limits how far the confirmed range can extend backward. This accounts for monthly buckets and records spanning multiple dates. An arbitrary earliest uploaded sample cannot establish a complete range.
- Freshness records the start of the confirmed recent scan (or a successful complete incremental sync). Uploading an old historical chunk cannot make recent data appear fresher. The displayed age updates every 30 seconds.
- The checkpoint is scoped to the selected data definitions, including route sharing. Changed sharing scopes require new confirmation; key rotation and account/cache reset clear the checkpoint. Once history is complete, ordinary anchored deltas avoid repeatedly rereading seven days.
- An existing installation initially shows that the date range is being confirmed. Existing uploads remain usable during that check. A range with no published health samples does not show the ready card.

## Validation

| Check | Result |
| --- | --- |
| iPhone 17 Pro simulator, iOS 26.3 | 40 tests passed: 35 unit/integration and 5 UI tests |
| Final recent-scan checkpoint refinement, iPhone 17 Pro | All 8 availability regression tests passed again on final source |
| iPhone SE (3rd generation) simulator, iOS 18.1 | 40 tests passed on final source |
| Large journal responsiveness, 100,000 synthetic indexed samples | Maximum main-actor scheduling gap: 11.1 ms on the Pro run, 13.0 ms on the SE run |
| Overview, Agents, active sync, paused sync, unconfirmed range | Automated navigation passed; Overview and Agents visually inspected |
| Largest accessibility text size on the SE | Date and freshness labels wrap/stack; scrollable without horizontal clipping; normal size restored |
| Signed Release archive and IPA export | Version 1.0.0, build 11 |

The new regression coverage checks incomplete buckets, pending catalog publication, empty results, resume/relaunch, separate record cursors, sharing-scope changes, cache reset, monthly and multi-day gaps, freshness, and more than eight recent records. It also caught and fixed a journal crash when reading an empty SQLite BLOB.

The sync orchestration tests use fixture readers and uploaders. These results do not establish throughput on a full real-device HealthKit library. The broader release gates recorded in `release-fixes-2026-09-08.md` still apply.

Evidence is stored locally under `artifacts/sync-availability/`. The test result bundles are:

- `~/Library/Developer/XcodeBuildMCP/workspaces/HealthMCP-990b23d666ee/result-bundles/test_sim_2026-09-09T21-21-41-642Z_pid13423_840ea4b7.xcresult`
- `~/Library/Developer/XcodeBuildMCP/workspaces/HealthMCP-990b23d666ee/result-bundles/test_sim_2026-09-09T21-24-09-641Z_pid13423_2d4e318f.xcresult`

IPA SHA-256: `218ccc2c209a0cd485f47132bc1544f1d9c20693cc6d6d2fc076a51052e89e99`.

## Distribution

Build **1.0.0 (11)**, App Store Connect ID `6a8bb4c9-41ef-4f69-a00b-052ee94bfd04`, is **VALID** and **IN_BETA_TESTING**. Membership was verified for the existing **Health MCP Internal** group (`0fc3d902-3ce6-466b-88cc-7f746f9d70dc`), with no additional groups. What to Test notes explain the first recent-data check and the new card. The existing prepared App Store version is attached to build 11; it has not been submitted for review or publicly released.
