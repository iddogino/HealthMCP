# V1 validation

Last updated September 7, 2026 (Pacific time).

The deployed service and website have passed their automated integration checks. Native tests pass, and the signed app is installed on the owner's iPhone 17 Pro. **The real HealthKit backfill, real-data decryption comparison, and APNs delivery checks remain open until the phone finishes syncing.** Synthetic tests are not evidence that those physical-device checks passed.

## Evidence

| Area | Result | Evidence |
|---|---|---|
| TypeScript | Worker/protocol and site typechecks passed | `npm run typecheck`, `npm run typecheck:site` |
| Protocol | 3 tests passed | `npm test` |
| Local integration | 21 checks passed | `artifacts/e2e-localhost.json` |
| Production integration | 23 checks passed, including both APNs endpoint probes and the push-fallback regression | `artifacts/e2e-mcp.healthmcp.cc.json` |
| Native app | 12 tests passed, zero failures/skips | Xcode result bundle `test_sim_2026-09-08T01-28-44-841Z_pid23677_ed54be1f.xcresult` |
| Crypto interoperability | Actual Swift output decrypted in Node and Python; Node output decrypted in Python | `artifacts/crypto-interop-report.json` |
| Live site | 13 HTTP, asset, security-header, 404, and Universal Link checks passed | `artifacts/site-check.json` |
| Browser QA | Home, connection guide, privacy, and support navigation inspected; copy-button success state checked; no horizontal overflow at the inspected window widths | Live `healthmcp.cc` in Codex browser |
| Dependency audit | Zero known npm vulnerabilities in root and site lockfiles at validation time | `npm audit`, `npm --prefix apps/site audit` |
| Apple distribution | Build 1.0.0 (3), including the device-test fix, processed as VALID; internal distribution is limited to the approved owner's account | `artifacts/asc-build-3-status.json`, TestFlight access receipts |
| Physical device | Installed and signed; actual onboarding, device registration, and push-token registration confirmed | Read-only onboarding flags and aggregate D1 status |

Build logs, result bundles, signing outputs, and device diagnostic files are deliberately ignored by Git. Xcode result bundles are under `~/Library/Developer/XcodeBuildMCP/workspaces/HealthMCP-990b23d666ee/result-bundles/` on the build Mac. Tests use synthetic fixtures and do not write fake samples into the owner's HealthKit store.

Redacted summaries are checked in under `docs/evidence/`. The exported build's embedded entitlements were inspected outside the restricted sandbox and confirm HealthKit, HealthKit background delivery, production APNs, and disabled debugger access.

## What the integration suite exercises

The suite creates isolated synthetic accounts and deletes them afterward. It uses real P-256 device signatures, the deployed OAuth provider, the official MCP SDK, D1, and R2. Checks cover proof of possession, replay and cross-user rejection, consent preview, browser-bound pairing, PKCE rejection and success, token refresh, all six MCP tools, both reference resources, signed downloads, local authenticated decryption, range lookup, deletion propagation, optional-group removal, immediate connection revocation, and cache-generation rotation.

The push regression checks that startup key-check/profile uploads do not suppress a pending visible fallback. A health-data upload clears it; completing a sync does not bypass the independent 15-minute request throttle.

APNs probes send an intentionally invalid all-zero token to Apple's sandbox and production endpoints. Both return `BadDeviceToken`. This exercises the request path and configured environment; it does **not** prove delivery or execution on an iPhone.

## What the native suite exercises

Nine unit tests cover Node/Swift wire compatibility, gzip and random nonces, signature format, compatible HealthKit units, category mapping, sleep union and UTC periods, SQLite anchor/deletion persistence, transaction rollback, and preserving pending work when HealthKit locks. Three UI tests cover read-only onboarding, visible backfill progress and pause controls, and overview/history/agent/settings navigation.

The first physical backfill exposed repeated `errorDatabaseInaccessible` errors after the phone locked. Build 3 pauses on that error, preserves anchors and pending chunks, avoids repeated per-chunk errors, and restores the screen-awake setting after a foreground transition. The regression test verifies that pausing retains completed progress and pending journal work.

## Remaining physical-device checks

1. Keep the phone unlocked with Health MCP open until the first backfill completes. A first export can include years of data; the app records progress and resumes interrupted work.
2. Run the development-only `-device-e2e` probe. It pairs an ephemeral client, verifies the encrypted key-check file, downloads a real chunk through MCP, decrypts it on the phone, and compares it with a fresh HealthKit read. Its report contains only checks and counts.
3. Copy the probe's short-lived OAuth session to the ignored local artifacts directory with owner-only permissions. `scripts/device-mcp-check.mjs` uses the official MCP SDK to request a sync without receiving the private health key or health values.
4. Verify silent APNs acceptance and a resulting completed sync while the app is backgrounded. After the request throttle permits, verify a visible fallback with the app force-quit, then tap it and verify foreground recovery.
5. Revoke the temporary validation connection using `-device-e2e-finish`, verify the token is rejected, and remove the exported session file.

Use `--` before app arguments with `devicectl`, for example:

```sh
xcrun devicectl device process launch --device DEVICE_ID --terminate-existing \
  cc.healthmcp.app -- -device-e2e
```

The release binary excludes the development probe. Never export the health key or plaintext samples to complete these checks.
