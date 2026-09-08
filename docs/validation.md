# V1 validation

Last updated September 8, 2026 (Pacific time).

The deployed service and website have passed their automated integration checks. Native validation includes build 5 on the owner's iPhone 17 Pro. Build 8 is available in the approved internal TestFlight group. **The real HealthKit → encryption → Cloudflare → MCP → on-device decryption comparison passes while the first backfill is still running.** Real APNs receipt also passed with the app open. Full-history completion, background completion, and the force-quit visible fallback remain separate open checks.

## Evidence

| Area | Result | Evidence |
|---|---|---|
| TypeScript | Worker/protocol and site typechecks passed | `npm run typecheck`, `npm run typecheck:site` |
| Protocol | 3 tests passed | `npm test` |
| Local integration | 21 checks passed | `artifacts/e2e-localhost.json` |
| Production integration | 23 checks passed, including both APNs endpoint probes and the push-fallback regression | `artifacts/e2e-mcp.healthmcp.cc.json` |
| Native app | 19 distinct tests passed across full and targeted runs, zero failures/skips | `docs/evidence/native-tests.json` |
| Crypto interoperability | Actual Swift output decrypted in Node and Python; Node output decrypted in Python | `artifacts/crypto-interop-report.json` |
| Live site | 13 HTTP, asset, security-header, 404, and Universal Link checks passed | `artifacts/site-check.json` |
| Browser QA | Home, connection guide, privacy, and support navigation inspected; copy-button success state checked; no horizontal overflow at the inspected window widths | Live `healthmcp.cc` in Codex browser |
| Dependency audit | Zero known npm vulnerabilities in root and site lockfiles at validation time | `npm audit`, `npm --prefix apps/site audit` |
| Apple distribution | Build 1.0.0 (8) processed as VALID and IN_BETA_TESTING; internal distribution is limited to the approved owner's account | `artifacts/asc-build-8-status.json`, TestFlight access receipts |
| Physical device | Incremental uploads, live OAuth/MCP round trip, real-data decryption comparison, and APNs delegate receipt confirmed | `docs/evidence/device-roundtrip.json`, `sync-performance.json` |
| Sync performance | 100,000-record stress test kept the UI executor responsive; real phone published 42 series while full sync remained unfinished | `docs/sync-performance.md` |
| Live dashboard | Build 5 keeps short/long action text at the same height and refreshes counters during the same sync; all three existing UI tests pass | `docs/evidence/live-dashboard.json` |
| Onboarding key copy | Build 6 explicitly points to Settings → Reveal private key; the complete key screen was visually checked with a synthetic key | `artifacts/ui-6-key-top.jpg`, `artifacts/ui-6-key-instructions.jpg` |
| Pairing keyboard | Build 7 dismisses the keyboard on outside tap and submission; it stays dismissed after canceling or approving consent. Field refocusing and editing still work | `docs/evidence/pairing-keyboard.json`, `artifacts/pairing-7-approved.jpg` |
| Key-copy feedback | Build 8 shows a checkmark and “Private key copied” in Settings and onboarding; simulator clipboard reads match the synthetic key | `docs/evidence/key-copy-feedback.json`, `artifacts/key-copy-8-settings-confirmed.png` |

Build logs, result bundles, signing outputs, and device diagnostic files are deliberately ignored by Git. Xcode result bundles are under `~/Library/Developer/XcodeBuildMCP/workspaces/HealthMCP-990b23d666ee/result-bundles/` on the build Mac. Tests use synthetic fixtures and do not write fake samples into the owner's HealthKit store.

Redacted summaries are checked in under `docs/evidence/`. The exported build's embedded entitlements were inspected outside the restricted sandbox and confirm HealthKit, HealthKit background delivery, production APNs, and disabled debugger access.

## What the integration suite exercises

The suite creates isolated synthetic accounts and deletes them afterward. It uses real P-256 device signatures, the deployed OAuth provider, the official MCP SDK, D1, and R2. Checks cover proof of possession, replay and cross-user rejection, consent preview, browser-bound pairing, PKCE rejection and success, token refresh, all six MCP tools, both reference resources, signed downloads, local authenticated decryption, range lookup, deletion propagation, optional-group removal, immediate connection revocation, and cache-generation rotation.

The push regression checks that startup key-check/profile uploads do not suppress a pending visible fallback. A health-data upload clears it; completing a sync does not bypass the independent 15-minute request throttle.

APNs probes send an intentionally invalid all-zero token to Apple's sandbox and production endpoints. Both return `BadDeviceToken`. This exercises the request path and configured environment; it does **not** prove delivery or execution on an iPhone.

## What the native suite exercises

Nine unit tests cover Node/Swift wire compatibility, gzip and random nonces, signature format, compatible HealthKit units, category mapping, sleep union and UTC periods, SQLite anchor/deletion persistence, transaction rollback, and preserving pending work when HealthKit locks. Five engine integration tests cover publication before enumeration ends, pause/cancellation, migration, and catalog recovery after restart. Two performance tests cover page indexing and UI responsiveness during 100,000-record indexing. Three UI tests cover read-only onboarding, live backfill progress and pause controls, and overview/history/agent/settings navigation.

The first physical backfill exposed repeated `errorDatabaseInaccessible` errors after the phone locked. Build 3 pauses on that error, preserves anchors and pending chunks, avoids repeated per-chunk errors, and restores the screen-awake setting after a foreground transition. Build 4 additionally removes the full-enumeration barrier and moves indexing, HealthKit result conversion, and serialization off the UI actor. The existing device journal was retained.

The development probe passed five real-device checks on September 8 at 17:07:05 UTC. The official MCP SDK found 42 series before the global completed-sync timestamp existed. A sync request at 17:08:11 UTC was accepted by APNs and received by the app delegate at 17:08:12 UTC. The temporary validation connection was revoked, its token returned HTTP 401, and its copied session credential was deleted. No private health key or plaintext was exported.

Build 5 reserves exactly two lines for the action text, with longer text truncated, and refreshes the dashboard's server totals every five seconds while syncing. Visual checks with short and long messages showed the same card and Pause-button positions. On the physical device, between 17:24:48 and 17:25:24 UTC, the same running sync updated the UI model from 8,037,696 to 8,175,118 cache bytes and from 3,814 to 3,919 chunks without an app restart. Both responses reported 44 series. Raw count-only snapshots and simulator screenshots are in ignored artifacts; the redacted verification is checked in.

Build 6 clarifies that saving a key copy is recommended and that the key can be revealed again in Settings. Simulator visual checks cover the explanation, key card, save acknowledgement, and Continue control using the existing synthetic demo key. Debug and Release builds pass. No new behavioral tests were added for this copy correction.

Build 7 gives the pairing field explicit focus control, dismisses it when tapping outside the field or submitting a code, and clears focus when consent closes or the Agents screen disappears. Manual simulator checks used a visible software keyboard and a synthetic pairing fixture to verify outside taps, refocusing and editing, submission, canceling, and approval. Approval cleared the code and displayed the connected demo agent without reopening the keyboard. The existing three UI tests pass, and the Debug build and Release archive/export pass. The exported IPA retains HealthKit, background delivery, production APNs, and disabled debugger access. This UI check does not repeat the live OAuth round trip or interrupt the owner's device sync.

Build 8 adds copy confirmation to the shared private-key view. The checkmark and “Private key copied” message last three seconds; repeated taps restart the confirmation, and both button states reserve the same space. Clipboard writes retain the existing device-only, 60-second expiration policy. Manual simulator checks exercised the Settings reveal sheet through simulated authentication and the onboarding key screen, using only the synthetic demo key. Clipboard reads matched the expected fixture in both flows, and the confirmation, reset, and stable layout were visually checked. All three existing UI tests pass after the final change. The Release archive/export and exported IPA entitlement checks also pass.

## Remaining physical-device checks

1. Keep the phone unlocked with Health MCP open until the full historical backlog completes, then confirm no pending work and a completed-sync timestamp. Existing uploaded data is already usable.
2. Verify a subsequent completed sync after an APNs request while the app is backgrounded. Foreground receipt has passed; background completion has not.
3. After the request throttle permits, verify a visible fallback with the app force-quit, then tap it and verify foreground recovery.

To repeat the real-data check before the entire backfill finishes, use the development-only `-device-e2e-incremental` probe. It pairs an ephemeral client, decrypts a downloaded chunk only on the phone, and writes checks/counts to `Documents/Validation/report.json`. Copy its separate OAuth session only to an ignored owner-only file, use `scripts/device-mcp-check.mjs`, then revoke it with `-device-e2e-finish` and delete the copied session. The original `-device-e2e` mode waits for sync to finish first.

Use `--` before app arguments with `devicectl`, for example:

```sh
xcrun devicectl device process launch --device DEVICE_ID --terminate-existing \
  cc.healthmcp.app -- -device-e2e-incremental
```

The release binary excludes the development probe. Never export the health key or plaintext samples to complete these checks.
