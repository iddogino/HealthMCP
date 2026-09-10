# Recent changes: release review — September 10, 2026

Follow-up: both findings were addressed in the [coverage and OAuth fixes](release-fixes-2026-09-10.md). The findings and original failing evidence below preserve the review as it was recorded.

**Verdict: hold the release of the latest candidate.** The review found a reproducible iOS coverage bug and a recurring production OAuth refresh failure. The existing regression suites pass, but these two cases prevent a release sign-off.

Reviewed `e1ec039..88534f2`: 40 changed files covering build 15's fresh-data priority, build 16's upload and catalog concurrency, Worker storage optimizations, native Cloudflare rate limits, diagnostics, tests and operational documentation. Relevant unchanged authorization, privacy, checkpoint and client code was inspected alongside the changes. The deferred historical backfill redesign remains outside this work.

## Findings

### P1 — A long pause can make incomplete coverage appear continuous

In [SyncAvailability.swift:275](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncAvailability.swift:275), `prepareFreshWindow` clips the catch-up start to the latest seven dates. If the previous checkpoint is older, the skipped interval is not represented by a fresh window. [The completion merge at line 340](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncAvailability.swift:340) nevertheless combines the old start and new end using `min`/`max`. That produces a continuous coverage claim across dates this catch-up never checked. The [initial-scan merge at line 214](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncAvailability.swift:214) has the same problem when onboarding resumes after a long pause.

Two added review tests reproduce this on both iOS 18.1 and 26.3.1. Their synthetic UTC timeline is:

| Step | Verified or claimed interval |
| --- | --- |
| Original recent scan | September 3, 00:00 → September 9, 12:00 |
| App resumes after two weeks; new catch-up checks | September 17, 00:00 → September 23, 12:00 |
| Resulting complete-range claim | September 3, 00:00 → September 23, 12:00 |
| Interval incorrectly bridged | September 9, 12:00 → September 17, 00:00 |

This can tell users all shared data is available when the intervening days still depend on historical indexing. It does not prove permanent data loss: the full-history scan can eventually fill the interval. The incorrect claim is already persisted before that work completes, however, and can survive a pause or relaunch. The merge can also carry forward `historyComplete` from an older checkpoint without establishing continuity to the new one.

**Required fix:** retain outstanding intervals and only merge coverage that overlaps or touches. Newest data can still run first. Apply the continuity rule to both fresh-window and initial-scan completion; preserve progress across interruptions and failed publication. This is a checkpoint correctness fix and does not require the deferred backfill redesign.

Evidence: [reproduction patch](/Users/iddogino/Dropbox/HealthMCP/artifacts/recent-changes-review-2026-09-10/freshness-gap-reproductions.patch), [test summary](/Users/iddogino/Dropbox/HealthMCP/artifacts/recent-changes-review-2026-09-10/native-corrected-summary.json). The temporary regression tests were removed from the app's test target after recording the failures; the patch preserves them for the fix.

### P1 — Production intermittently rejects a newly issued refresh token

The production E2E run reached consent, PKCE/token exchange, MCP initialization, tools and decryption successfully. Its first refresh attempt then failed at [scripts/e2e.ts:103](/Users/iddogino/Dropbox/HealthMCP/scripts/e2e.ts:103):

```text
OAuth refresh returned 400: invalid_grant (Invalid refresh token)
```

That token had not previously been refreshed or revoked. The test had not reached its connection-revocation step. This repeats the unexplained refresh HTTP 400 recorded during the native-rate-limit rollout; it is no longer reasonable to dismiss that earlier failure because a rerun passed.

A separate disposable-account probe in this review successfully refreshed after a ten-second delay, used the new access token to initialize MCP, and cleaned up. The result confirms intermittency; it does not clear the failed release check. Both live test accounts and the separate probe account were deleted after use. Successful token responses were never logged.

The application delegates `/token` to [the OAuth provider configured here](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/index.ts:65). In pinned provider version 0.10.3, [the failing branch](/Users/iddogino/Dropbox/HealthMCP/node_modules/@cloudflare/workers-oauth-provider/dist/oauth-provider.js:2011) reads a grant from `OAUTH_KV` and rejects the supplied token if its hash matches neither the current nor previous stored refresh token. The token endpoint does not use the new routine native-rate-limit helper.

**Root cause remains unconfirmed.** A stale grant read is a plausible explanation, not a demonstrated diagnosis. Cloudflare documents that KV is eventually consistent and even same-location visibility immediately after a write is not guaranteed. [Cloudflare KV consistency documentation](https://developers.cloudflare.com/kv/concepts/how-kv-works/).

**Required follow-up:** trace grant revision/rotation behavior with disposable credentials, resolve the unexpected rejection, and add a regression for first refresh and repeated rotation. If a consistency race is confirmed, address the grant-state authority rather than hiding `invalid_grant` with test retries. Then rerun the complete production and packaged-client flows, including the deletion and revocation checks that this failing run never reached. Agent session continuity cannot be signed off while valid refreshes can fail without explanation. The review does not establish that the rate-limit changes introduced this issue.

Evidence: [failed production run](/Users/iddogino/Dropbox/HealthMCP/artifacts/recent-changes-review-2026-09-10/production-e2e.log), [separate successful probe](/Users/iddogino/Dropbox/HealthMCP/artifacts/recent-changes-review-2026-09-10/oauth-probe-observations.json).

## Release packaging

App Store Connect still has **1.0.0 build 14**, state **WAITING_FOR_REVIEW**. The latest iOS code reviewed here is build **16**, previously installed on the connected iPhone. Builds 15 and 16 do not appear in the current ASC build list. The current production Worker is `40b08afc-be5a-438b-a4b1-56aba74d1f60`.

After the blockers are resolved, an updated signed build must be uploaded and selected for review to ship these iOS changes. The existing submission was left intact. Release mode is manual, so approval alone does not automatically publish it.

ASC validation reported no metadata warnings. Its sole error was that an already-submitted version is not editable, which is expected in `WAITING_FOR_REVIEW`. The API cannot independently confirm the App Privacy publication state; this review did not recheck the browser-only declaration. [ASC state evidence](/Users/iddogino/Dropbox/HealthMCP/artifacts/recent-changes-review-2026-09-10/asc-version.json).

## Validation and reviewed safeguards

| Check performed during this review | Result |
| --- | --- |
| TypeScript type checking | Passed |
| Worker/protocol/client regression suite | 44/44 passed |
| Existing iOS unit tests | 55/55 passed on each of iOS 18.1 and 26.3.1 |
| Existing iOS UI tests | 8/8 passed on each runtime |
| Added long-pause coverage reproductions | Both failed on each runtime: four failing test runs |
| Production API/MCP E2E | 15 checks passed before OAuth refresh failed; cleanup also passed |
| Independent production OAuth probe | Refresh and subsequent MCP initialization passed; cleanup passed |
| ASC version/build/readiness inspection | Build 14 waiting for review; latest iOS changes not attached |

The corrected native result contains 65 distinct tests run on two devices: 126 passing executions and four failing executions. An initial unsigned simulator run could not access Keychain; enabling simulator signing resolved the UI-test setup failure. An intermediate test-source compile error was also corrected before the recorded run. Neither setup failure is reported as a product defect.

No additional actionable defect was found in the following reviewed changes:

- Eight concurrent uploads with a cancellable eight-starts-per-second pacer, including retries and deletes.
- Four concurrent catalog publications, individual successful acknowledgements, and preservation of failed work in the outbox.
- Fresh-data preemption at page/batch boundaries, separate HealthKit cursors, and privacy cleanup of the new checkpoint tables, apart from the continuity bug above.
- Atomic replay-nonce claims, upload reservation/publication, privacy fences, ambiguous-commit recovery and durable cleanup of superseded R2 objects.
- Native limiter identity checks, per-user and shared keys, unchanged minute budgets, `Retry-After`, fail-closed behavior, and retained durable quota/admission controls.
- Optional timing and operational diagnostics without health payloads or credentials.

The earlier exact-commit deployment validation also exercised actual native bindings in local workerd and completed production and packaged-client flows. Those earlier successes remain useful coverage but do not supersede the refresh failure reproduced in this review. Native shared keys retain the documented per-Cloudflare-location semantics accepted for this change.

Simulator tests use fixtures. This review reused the physical build-16 observations recorded earlier today; it did not complete the phone's full historical backfill or establish overnight background scheduling reliability. The conservative complete-history boundary during partial backfill remains the intentionally deferred behavior, separate from the false interval merge identified above.

All raw evidence is under `artifacts/recent-changes-review-2026-09-10/`. Product source, deployment and submission state were not changed by the review. A compact machine-readable record is in `docs/evidence/recent-changes-review-2026-09-10.json`.
