# Coverage and OAuth release fixes — September 10, 2026

The two blockers in the [release review](recent-changes-review-2026-09-10.md) are addressed. The Worker fix is deployed as `73a42bf5-5b3d-4d57-bd7a-bdcb8474012f`. Signed iOS build **1.0.0 (17)** was installed on the paired iPhone. The device disconnected before launch validation; the request to reconnect remains pending. App Store Connect's build-14 submission was not changed.

## Continuous coverage after an absence

The app still checks the newest week first. If an older checkpoint leaves an intervening gap, it now queues that interval as durable catch-up work. Completing the newest window alone cannot certify the skipped dates. The gap and its acknowledgements survive app relaunch, and existing clipped windows retain their original HealthKit predicates and record cursors.

Both initial-scan and fresh-window completion now require overlapping or adjacent intervals before combining them into a continuous range. Disjoint verified intervals cannot become a complete range through `min(start)` / `max(end)` alone.

Build 17 also repairs legacy coverage bookkeeping. Older builds could already have persisted an overbroad claim, so the upgrade conservatively retains the verified recent suffix while normal historical indexing re-establishes older coverage. It preserves uploaded data, keys, anchors and the partial-history span. The deferred full-history backfill redesign is unchanged.

Five added regressions cover both review reproductions, newest-first ordering across a two-week absence, completion after relaunch, preservation of old record cursors, and preservation of uploaded history during upgrade. The two original reproductions now pass, and complete coverage advances to the new endpoint only after the gap is acknowledged.

## OAuth refresh consistency

The pinned OAuth provider stores rotating grant state in `OAUTH_KV`. A deterministic regression now holds the pre-exchange grant visible after token issuance and reproduces the exact production symptom: the first refresh returns `400 invalid_grant / Invalid refresh token`. Cloudflare documents [eventually consistent KV reads](https://developers.cloudflare.com/kv/concepts/how-kv-works/), and the upstream project also tracks a [grant-rotation consistency hazard](https://github.com/cloudflare/workers-oauth-provider/issues/214).

The provider now uses a request-scoped adapter backed by the primary D1 `oauth_state` table for client registrations, grants and access tokens. The provider version, token format, hashes, encrypted properties, PKCE, scopes and lifetimes are unchanged. APNs JWT caching remains in KV. Native Cloudflare rate-limit bindings remain in place; no routine D1 rate counters were reintroduced.

Writes compare the revision read by the request, so a stale writer cannot replace newer grant state. Conflicts return `temporarily_unavailable` with a short retry interval. Grant retirement atomically retires its tokens; token insertion requires a live grant. Tombstones fence concurrent revocation/import and retain failed legacy cleanup for the cron to retry. Expired state is removed by the existing scheduled job.

The stale-KV regression passes with D1 through eight immediate refresh rotations and usable access tokens. Additional tests cover existing-token migration, expiry, paginated deletion, revision conflicts, issuance/revocation races, and the migration gate. This establishes and removes the stale-read failure mechanism; it does not retrospectively trace the precise Cloudflare cache state of the earlier production failures.

## Production migration and validation

The migration was rehearsed against isolated local workerd, preserving a pairing created before the transition. Production then briefly gated new OAuth mutations with a retry response while existing MCP access remained available. All **27** legacy OAuth records were transferred or recognized as revoked and verified inside SQLite. The original test pairing continued to work after cutover and completed five immediate refresh rotations with usable access tokens.

After successful production API/MCP and packaged-client checks, the remaining **25** legacy OAuth records were removed from KV. The difference is the grant/access-token cleanup of the disposable migration fixture. APNs cache entries and encrypted health objects were outside the migration prefixes.

The transfer tool preserves absolute expiration dates, uses idempotent inserts and respects revocation tombstones. Private temporary transfer files are removed, and evidence contains counts and a digest rather than authorization values. Wrangler's remote bulk-import output differs from local query output; verification therefore uses a SQL `CHECK` invariant rather than parsing SELECT rows from that output. An initial Cloudflare management-API request also returned error 7403; a successful connectivity check and schema retry resolved it. No token retry was added to make the production OAuth tests pass.

| Validation | Result |
| --- | --- |
| TypeScript type check | Passed |
| Worker, protocol and client regressions | 51 passed, including seven OAuth/storage regressions |
| iOS 26.3.1 simulator | 68 passed: 60 unit tests and eight UI tests |
| iOS 18.1 simulator | The same 68 passed |
| Local API/MCP E2E | All 21 checks passed with the final Worker code |
| Local packaged desktop client | All five checks passed |
| Local and production existing-pairing migration probes | Access retained during the gate, then existing-token refresh and five rotations passed |
| Production API/MCP E2E before legacy cleanup | All 21 checks passed |
| Production API/MCP E2E after legacy cleanup | All 21 checks passed; deployed health check confirms D1 OAuth storage |
| Production packaged desktop client | All five checks passed, including automatic refresh and decrypted tool results |
| Signed Release archive/export | Build 17 succeeded; signature verification passed outside the restricted sandbox |
| Physical iPhone delivery | Installation succeeded; connection was lost before launch/readback validation |

The native suite initially caught a test assertion comparing a freshly computed observation timestamp rather than the preserved range. Comparing the actual range and scope corrected that test. The final native run has no failures. The production E2E checks use disposable accounts and clean them up afterward; real health values and credentials were not inspected.

Ad hoc IPA SHA-256: `6d8ebb3bfc226b42f2dfec204740467a36ae824e1921e0eacaf3ee972186f644`.

Raw evidence is in `artifacts/release-fixes-2026-09-10/`, with a consolidated [evidence record](evidence/release-fixes-2026-09-10.json). The final device discovery still reports the iPhone as unavailable, so physical launch and sync validation remain unverified. See [operations](operations.md#oauth-storage-and-migration) for the migration procedure. Future rollbacks must retain the D1 adapter; switching back to a legacy KV-only Worker would discard current authorization state.
