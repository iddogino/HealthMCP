# Release fixes — September 8, 2026

The eleven code findings in the [readiness review](release-readiness-review-2026-09-08.md) have implemented fixes and regression coverage. The API and site are deployed. Build 10 (`56685527-cbbf-420f-99c9-836b7429e661`) is VALID, has Apple’s `IN_BETA_TESTING` state, and is available in the existing internal TestFlight group, following build 9 with the same app behavior and complete third-party notices in the exported client. **Public launch remains gated on physical-device/assistant validation and submission setup below.**

## Fixes

| Review finding | Change and validation |
|---|---|
| 1. Privacy changes race sync | Durable Keychain intent gates new sync before the first await. Changes retry across relaunch. Signed generation/privacy revisions prevent delayed requests from republishing removed data. Native exclusion/relaunch and Worker in-flight reset/deletion tests pass. |
| 2. R2 success / D1 failure hides records | Unique physical versions are published through the D1 index only after R2 succeeds. Ambiguous commits preserve indexed data and the previous good version. Old journal coverage checks identify missing indexes and queue durable repair uploads. Failure-injection and restart regressions pass. |
| 3. Restored preferences bypass onboarding | Bootstrap reconciles preferences with complete device credentials and restarts registration when device-only credentials are absent. Restored-state tests pass. |
| 4. Lost deletion response strands device | Persisted deletion intent, 30-day authenticated server receipts, and checkpointed local cleanup support retry after lost responses or partial key removal. Both failure points pass. |
| 5. Backfill repeats full-period work | Enumeration coalesces each period to an early snapshot plus one final catch-up; derived invalidation follows actual dependencies. Ten synthetic heart-rate pages now cause two day reads and no unrelated monthly summary/ring rebuilds. Dirty work survives restart. Real-device elapsed backfill time is still unmeasured for this build. |
| 6. Unbounded admitted storage/write work | Atomic physical-storage reservations enforce per-user/global byte and object quotas, admission limits and request throttles. Cleanup remains available at capacity. Counter consistency verified in production. Operator billing/notification setup remains a separate operational gate. |
| 7. Unbounded push completion | Push and background HealthKit callbacks use a 23-second slice with exactly-once completion and cancellation. A stalled-work deadline regression passes; real background execution remains a device gate. |
| 8. Late workout details discarded | Assembled workout objects can be replaced safely. Late heart rate, routes, route deletion, energy and distance changes invalidate overlapping indexed workouts. Native dependency and Worker replacement tests pass. |
| 9. Overlapping intervals omitted | Manifests use actual chunk coverage. Unknown old coverage is included conservatively until the phone publishes its journal boundaries. Cross-midnight/month and legacy-coverage tests pass. |
| 10. OAuth completion failure strands pairing | Completion leases recover provider or redirect-write failures; browser polling retries transient failures. Attempts and active connections are bounded. Failure-injection and deployed OAuth/refresh/revocation tests pass. |
| 11. Failed bootstrap becomes permanent | Concurrent callers await one initialization task. Failed startup remains retryable with a visible recovery action and foreground/protected-data retry. Bootstrap failure and concurrency tests pass. |

The two design recommendations are also implemented: new keys contain 130 random bits plus a checksum, with legacy-key compatibility; a fixed local MCP connector and helpers ship inside the signed iPhone app. The connector decrypts on the computer and exposes locally defined tools without executing server-supplied source. Pairing consent explicitly explains sharing requested records with the chosen third-party AI provider. Key and consent sheets scroll on small screens, and key text wraps at accessibility sizes.

## Validation

- Worker/protocol/client: **29 automated tests passed**, including partial R2/D1 writes, quota races, cache resets, deletion receipts, range overlap, OAuth leases, trusted download boundaries and local pagination.
- Native: the full **29-test suite passed on iPhone 17 Pro / iOS 26.3 and iPhone SE 3 / iOS 18.1**. The final three UI tests also passed on iPhone 17 Pro Max. One additional legacy-repair/restart test passed after that run, bringing the suite to 30 tests. No production app code changed for that extra test.
- **21 API/MCP HTTP end-to-end checks passed locally and in production** using isolated synthetic accounts, including signatures, replay rejection, cross-account isolation, OAuth/PKCE/refresh, six tools, encryption, deletion, revocation and rotation.
- The **actual packaged stdio connector passed against the production service**: browser OAuth, phone-consent API, callback state/PKCE, private key setup, decryption check, expired-token refresh, tool output and revocation. Synthetic secrets and accounts were removed. This is an MCP SDK harness; an actual named assistant conversation has not yet been exercised.
- Swift → Node, Swift → Python and Node → Python crypto interoperability passed for new and legacy keys. TypeScript checks and the site production build passed.
- Large Dynamic Type key/copy UI was inspected on iPhone SE. Three 1320×2868 screenshots were inspected and uploaded to the draft store listing. The CLI capture workflow is experimental; upload processing completed for all three assets.
- The desktop ZIP rebuilds reproducibly. Its executable matches the production-tested bundle; third-party notices are generated from actual bundled inputs. The final signed-app resource is checked against the source ZIP.
- Production logical and physical quota counters match their source tables. The bounded legacy R2 reconciliation scan is running; completion of the whole historical bucket is not claimed.

Detailed logs, screenshots, IPA/archive files and isolated fixtures are under `artifacts/release-fixes-*` and `artifacts/store-screenshots`. Machine-readable summary: [release-fixes.json](evidence/release-fixes.json).

## Deployment and submission

- API Worker: `6038bfae-15ef-4ca1-8ac1-6e5305fa97cc`; migrations 0003 and 0004 applied after recording a D1 recovery bookmark.
- Site: `ed9d6203-ed1a-41ad-bb49-a1032c996758`; support, privacy and trusted-client guide are live at healthmcp.cc.
- App Store draft: aligned to 1.0.0, manual release, Health & Fitness category, age rating, content rights, copyright, description, support/privacy URLs and three screenshots staged.
- App Store readiness checks fell from **34 blockers to 2**: review details and availability. App Privacy publication cannot be confirmed by the API and is still required.

## Remaining before public launch

1. **Physical device:** reconnect/unlock the iPhone and complete a full historical backfill, lock/background resume and force-quit notification fallback on the release build. The Mac still reports the target iPhone unavailable. Existing evidence proves an earlier incremental real-data round trip and foreground APNs receipt, not these remaining cases.
2. **Supported assistant:** exercise the actual user workflow in a named local-MCP assistant, including the exported bundle. SDK tests do not prove every assistant UI's compatibility. Remote-only connector UIs cannot run this local client.
3. **Apple setup:** sign in to the existing App Store Connect browser tab to publish App Privacy and initialize availability. A private App Review contact phone number is pending; review notes are prepared in `docs/app-review-notes.md`.
4. **Public email:** support@healthmcp.cc is on the site and listing. The domain had no MX routing at inspection; the forwarding destination is pending. No successful email delivery is claimed.
5. **Operations/accessibility:** choose an operator notification destination and configure account-level billing alerts; finish a VoiceOver pass and physical large-history memory/timing measurements. Application quotas do not cap all platform charges.

Existing users retain their current key and cache. New keys use the stronger format; an existing user adopts it through explicit key rotation, which revokes connections and rebuilds the cache. No owner's key, real health values or existing account were exported or deleted during this work. No App Store review submission, public release or wider tester rollout was performed.
