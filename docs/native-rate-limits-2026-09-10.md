# Native Cloudflare request limits — September 10, 2026

Worker version `40b08afc-be5a-438b-a4b1-56aba74d1f60` is deployed to `mcp.healthmcp.cc`. The change is compatible with existing iOS and MCP clients; it requires no app update or database migration.

## Implementation

Signed device requests, chunk uploads/deletes, MCP requests and encrypted downloads now use eight native bindings: one per-user limiter and one shared limiter for each request class. Keys use verified account IDs, after signature/token validation. A rejected user does not consume the shared budget. Native rejection returns HTTP 429 with `Retry-After: 60`; unavailable bindings fail closed with HTTP 503 and `Retry-After: 5`.

The numeric minute budgets are unchanged. See [operations](operations.md#native-request-throttling) for values and configuration. Both per-user and shared keys apply per Cloudflare location and are permissive, as documented in [Cloudflare's rate-limit API](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/). They do not implement exact worldwide quotas. Storage reservations, account admission, nonce replay protection, publication and privacy fences remain durable D1 operations. The infrequent 5-minute/hour/day security throttles also remain in D1.

Each upload avoids four D1 rate-counter write statements. A new chunk now executes five explicit SQL write statements rather than nine, in five D1 round trips. Database triggers still maintain cache and quota totals, and replacement cleanup retains its separate durable work. MCP and download requests each avoid two serial D1 limiter calls.

## Validation

- TypeScript type checking passed.
- All 44 Worker/protocol/client regression tests passed. Added coverage checks per-user isolation, shared budgets, binding failures, authenticated identity enforcement, replay protection, HTTP retry delays and the removal of rate-counter SQL from routine operations.
- `npm run test:ratelimits` passed against an isolated local workerd instance using actual native bindings with reduced budgets. It verified per-user rejection, shared rejection across two users, `Retry-After`, and continued status/account cleanup access after upload throttling.
- All 21 API/MCP end-to-end checks passed locally and in production, including signed uploads, consent pairing, official MCP SDK tools, encrypted downloads/local decryption, deletion, revocation, rotation and account cleanup.
- The packaged desktop client passed its five production checks: OAuth consent, private-key setup, token refresh with decrypted tool results, revocation and cleanup.

One initial production end-to-end run returned HTTP 400 during OAuth token refresh. The same deployed Worker subsequently passed the complete suite and the packaged client's separate refresh test. The first error body was not captured, so its cause remains unconfirmed. The E2E script now reports OAuth error codes/descriptions on failure without printing successful token responses. The failed run's synthetic accounts were cleaned up, and its log is retained separately. No OAuth implementation changes or automatic retries were introduced to make validation pass.

## Production measurements

A disposable account uploaded 24 new and 24 replacement encrypted chunks, then issued 24 empty deletes and eight catalog updates. All requests succeeded and the account and data were deleted afterward. Payloads were approximately 3.9 KB; upload bursts used eight concurrent requests without the app's additional pacing.

| Workload | Mean request time | Requests/second | Mean D1 binding wait | Mean R2 binding wait |
|---|---:|---:|---:|---:|
| New chunks | 560 ms | 12.09 | 288 ms | 197 ms |
| Replacements | 640 ms | 9.92 | 378 ms | 185 ms |
| Empty deletes | 258 ms | 26.22 | 220 ms | 0 ms |
| Catalog updates (serial) | 180 ms | 5.55 | 145 ms | 0 ms |

These are synthetic Mac-to-production measurements, not a phone backfill benchmark. R2 wait was much lower than the earlier same-day benchmark, so the throughput change cannot be attributed solely to native throttling. New uploads still require five D1 round trips. The phone's existing eight-starts-per-second pacer and eight concurrent upload limit remain unchanged.

Raw deployment, test and benchmark evidence is retained under `artifacts/native-rate-limits-2026-09-10/` (excluded from Git).
