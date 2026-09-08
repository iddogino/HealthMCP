**Health MCP release readiness review — September 8, 2026**

**Verdict: keep V1 in internal TestFlight. I would not launch it publicly yet.** The normal authentication, encryption, upload, and MCP flows work, but recovery, privacy-setting concurrency, and backfill efficiency have release-blocking gaps. This review identifies **six P1 issues and five P2 issues**, followed by separate submission and validation requirements. No P0 issue was demonstrated.

Reviewed source: commit `54eeaec`, corresponding to the current build 1.0.0 (8). Scope included all first-party iOS production source, HealthKit mappings and readers, local journal, encryption and reference implementations, Worker routes, OAuth/MCP, D1/R2 lifecycle, APNs, marketing/support/privacy pages, build and deployment configuration, and existing tests and operational evidence. Third-party libraries were checked through dependency advisories and relevant integration boundaries; this was not a line-by-line audit of every vendored library. Production code and deployed services were not changed.

P1 means fix before widening distribution. P2 means a concrete correctness or reliability problem that should be resolved for a dependable V1.

1. **[P1] Privacy changes do not exclude a concurrent sync.**

   Locations: [AppModel.swift:110](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/AppModel.swift:110), [AppModel.swift:212](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/AppModel.swift:212).

   Disabling a group pauses the existing sync, then awaits several server deletions before removing the group from the enabled set. During those awaits, a push, HealthKit callback, or foreground transition can start another sync. `startSync` checks neither `busy` nor a privacy-operation state. That new run can capture the old enabled groups and upload a series after its deletion, leaving supposedly disabled data available to agents. Route changes, rotation, and account deletion use the same unprotected coordination pattern; privacy actions can also overlap one another.

   **Evidence:** an isolated native probe sets `busy = true` and confirms that `startSync` still creates a running sync. The subsequent data-restoration scenario follows from the enabled-group update order and the Worker's acceptance of uploads after a series deletion; that full race was not exercised against the owner's data.

   **Fix:** serialize privacy operations with sync creation, acquire the exclusion state before the first await, and queue incoming triggers until the operation finishes. Validate an incoming push during each deletion/reset stage and assert that removed series and old-key uploads cannot reappear.

2. **[P1] A retried workout/ECG upload can report success while remaining invisible to MCP.**

   Location: [storage.ts:17](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/storage.ts:17).

   Uploads write R2 before inserting the D1 chunk index. If R2 succeeds and the D1 write fails, the retry sees the record object in R2 and immediately returns `stored: true, unchanged: true`. It never repairs the missing index. The iPhone treats that response as an acknowledgement, clears its dirty marker, and can publish a catalog entry for data that manifests will never return. Repeated retries keep taking the same shortcut.

   **Evidence:** failure injection against the actual production `upload` function produced one stored R2 object, zero indexed chunks, and a successful retry response. The observation is saved in [worker-fault-results.json](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/worker-fault-results.json).

   **Fix:** make acknowledgement depend on both a valid current-generation object and its durable index. Retry must reconcile partial writes. Add an R2-success/D1-failure regression and check availability through `get_workouts`, not just the PUT response.

3. **[P1] Restoring onto a new iPhone can bypass registration and strand the user on the dashboard.**

   Locations: [AppModel.swift:63](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/AppModel.swift:63), [Crypto.swift:24](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/Crypto.swift:24).

   Onboarding state is stored in UserDefaults, while the identity, account ID, and health key use `ThisDeviceOnly` Keychain storage. A restore can therefore preserve `onboarded` or a later onboarding step without the device credentials. Bootstrap creates a new key but leaves the account ID empty and trusts the restored onboarding state. Every sync then silently fails its empty-ID guard. Registration exists only in the first onboarding action, which this state bypasses. This contradicts the documented recovery path of re-onboarding on a new phone.

   **Evidence:** a native probe with restored onboarding preferences and an empty isolated Keychain produces `initialized = true`, `onboarded = true`, no account ID, and no sync after pressing the equivalent of Sync. Apple's [Keychain accessibility documentation](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly) confirms these items do not migrate to another device.

   **Fix:** reconcile preferences with a complete, usable identity before selecting the UI. Missing credentials must reset onboarding and establish a new account and journal consistently. Validate completed and partially completed onboarding restores.

4. **[P1] Losing the account-deletion response prevents local cleanup and normal recovery.**

   Locations: [AppModel.swift:278](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/AppModel.swift:278), [security.ts:47](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/security.ts:47), [storage.ts:108](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/storage.ts:108).

   The server removes the user before the iPhone clears its keys, account ID, journal, and onboarding state. If that response is lost, or local cleanup fails afterward, the old credentials remain. A retry receives `401 Unknown device` and throws before cleanup again. Sync and rotation also fail for that account. Reinstalling is not a reliable escape because Keychain items can survive app removal.

   **Evidence:** deleting a synthetic account through the production reset function and then retrying authentication produces the permanent 401 path. The iOS cleanup ordering was traced directly; no real account was deleted in this review.

   **Fix:** persist deletion intent and make the operation recoverable across both server completion and local cleanup. An authenticated receipt/tombstone or equivalent protocol should distinguish already-deleted state from invalid credentials. Test a dropped successful response and interruption at every local cleanup step.

5. **[P1] Backfill repeatedly rebuilds and uploads the same complete periods.**

   Locations: [SyncStore.swift:157](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncStore.swift:157), [SyncEngine.swift:104](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncEngine.swift:104), [HealthReader.swift:48](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Health/HealthReader.swift:48).

   Each 1,000-sample page dirties its raw period plus the monthly daily summary and activity rings. The engine drains those chunks between pages, but `readChunk` queries the entire period from HealthKit, independently of how far enumeration has progressed. Later pages from that same period therefore repeat the full read, serialization, encryption, and upload. Even heart-rate pages invalidate summaries and rings that do not depend on individual heart-rate samples. Each daily-summary rebuild issues seven statistics queries plus sleep and workout queries.

   **Evidence:** ten synthetic pages containing 10,000 heart-rate samples from one historical day caused **nine reads each** of that full day, the same monthly daily summary, and the same monthly activity rings. This measures redundant operations, not real-device elapsed time. It provides a concrete remaining source of slow backfills; it does not establish that every observed delay has this cause.

   **Fix:** coalesce invalidations across enumeration pages, track actual derived-data dependencies, and avoid rebuilding a period whose complete snapshot is already current. Preserve early useful uploads and cancellation. Validate full HealthKit backfill duration and memory, not only SQLite indexing responsiveness.

6. **[P1] Public registration grants unbounded storage/write access at the application layer.**

   Locations: [index.ts:22](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/index.ts:22), [storage.ts:5](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/storage.ts:5), [wrangler.jsonc:15](/Users/iddogino/Dropbox/HealthMCP/apps/worker/wrangler.jsonc:15).

   Anyone can generate a software P-256 key and register. The per-IP registration limit does not restrict subsequent uploads. A registered caller can continuously store new workout/ECG UUID objects or rewrite other chunks; there is no per-account write rate, storage quota, object quota, or admission policy. The 16 MB request cap and per-request CPU limit do not bound aggregate R2, D1, or Worker usage. Envelope validation verifies format, not that bytes came from HealthKit.

   **Evidence:** the local E2E suite successfully registers software-generated identities. All upload and infrastructure configuration paths were inspected for application-level quotas. No production abuse/load test was performed, and separately managed account-wide WAF or billing controls were not verified.

   **Fix:** add enforceable per-account and aggregate budgets, write throttling, monitoring/alerts, and an admission policy appropriate to the launch. Keep cleanup available when limits are reached. Device attestation can supplement these controls but does not replace quotas.

7. **[P2] Background push awaits an unbounded sync without a background-time deadline.**

   Locations: [HealthMCPApp.swift:43](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/HealthMCPApp.swift:43), [HealthQueryRunner.swift:23](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Health/HealthQueryRunner.swift:23), [APIClient.swift:15](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/APIClient.swift:15).

   The remote-notification delegate awaits bootstrap and the entire sync before invoking its completion handler. There is no push-specific deadline or bounded work budget, although individual HealthKit queries and HTTP requests can each take 90 seconds and a backfill can take much longer. The BGProcessing path has an expiration handler; this push path does not. Apple gives the background-push handler [30 seconds to finish and call completion](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

   **Fix:** perform a bounded incremental slice, cancel and preserve pending work before the deadline, and schedule eligible remaining work through BGProcessing. Ensure the completion handler runs exactly once on success, error, and expiry. Real background completion is still an open physical-device gate.

8. **[P2] Write-once workout objects permanently discard late-arriving details.**

   Locations: [storage.ts:17](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/storage.ts:17), [WorkoutReader.swift:27](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Health/WorkoutReader.swift:27), [SyncEngine.swift:227](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/SyncEngine.swift:227).

   The exported workout combines the workout object with separately queried heart-rate and route samples. Apple's [documented route-save sequence](https://developer.apple.com/documentation/healthkit/creating-a-workout-route) saves the workout before saving/associating its route. If Health MCP exports in between, it stores an incomplete record. The iPhone rereads recent workouts later, but the Worker ignores every replacement once the first object exists. This is a flaw in the spec's immutable-workout assumption as applied to the assembled export, separate from the missing-index failure in finding 2.

   **Evidence:** two different envelopes uploaded for the same workout return success while retaining only the first envelope. The Worker behavior was reproduced; a live late-arriving Watch route was not simulated.

   **Fix:** permit versioned or replaceable assembled workout records and invalidate them when associated data changes. Validate a workout first seen without a route, then with its route and heart-rate detail.

9. **[P2] Date-range manifests omit chunks containing overlapping intervals.**

   Locations: [storage.ts:79](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/storage.ts:79), [mcp.ts:10](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/mcp.ts:10), [SeriesDefinition.swift:42](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Health/SeriesDefinition.swift:42).

   MCP tells agents to include interval samples that overlap the requested inclusive UTC days, but the manifest filters only the assigned chunk period. A sleep interval from September 1 at 23:00 UTC to September 2 at 07:00 UTC belongs to the September 2 chunk. A September 1 request returns no such chunk, so local filtering cannot recover the overlapping hour. Workouts and cumulative intervals can fail in the opposite direction when they start before the requested range.

   **Evidence:** the production manifest function omits a stored next-day sleep chunk when querying the preceding day, consistent with the iOS end-date bucket assignment.

   **Fix:** make manifest selection cover actual interval overlap, or explicitly revise the tool contract to bucket-date semantics. Coverage metadata is more reliable than assuming every interval fits within one adjacent day. Add cross-midnight and cross-month cases.

10. **[P2] A transient OAuth completion failure strands an approved pairing.**

    Location: [pairing.ts:35](/Users/iddogino/Dropbox/HealthMCP/apps/worker/src/pairing.ts:35).

    Polling claims an approved pairing by changing its status to `completing`, then calls the OAuth provider and saves the redirect. If either awaited operation fails, nothing releases or recovers the claim. Later polls return `completing` without retrying authorization. The authorization page also stops polling on its first non-OK response, so the user must restart pairing rather than recover the approved session.

    **Evidence:** injecting one provider failure leaves subsequent polls at `completing`; the provider is called only once.

    **Fix:** use a recoverable completion state/lease and an idempotent completion strategy, including the case where the provider committed but the redirect write failed. Give the browser a retriable response and test both failure points.

11. **[P2] Failed bootstrap is permanently treated as completed for the process.**

    Location: [AppModel.swift:53](/Users/iddogino/Dropbox/HealthMCP/apps/ios/HealthMCP/Core/AppModel.swift:53).

    `hasBootstrapped` is set before the first await, and `initialized` becomes true even on failure. Any storage or Keychain failure leaves later bootstrap calls as no-ops. Foreground entry starts sync rather than retrying initialization, so unlocking after a failed protected-data startup does not necessarily recover the app. Concurrent bootstrap callers also return before the initial caller has actually finished.

    **Evidence:** a native probe induces an initialization failure with an invalid isolated key, repairs storage, and calls bootstrap again. The repaired key is never loaded. This reproduces the retry-state defect; it does not simulate an actual pre-unlock OS launch.

    **Fix:** represent uninitialized, initializing, ready, and retryable failure states separately. Concurrent callers should await one initialization task, and foreground/protected-data availability should retry failed initialization.

**Submission and real-world validation remain separate release gates.**

| Gate | Current evidence | Required before public release |
|---|---|---|
| App Store version setup | `asc validate` reports 34 blocking checks, two warnings, one informational check for version 1.0. Build 1.0.0 (8) is VALID. | Complete metadata, review details, screenshots, category, content rights, age rating, copyright, availability, and attach the intended build. Align the store and binary version configuration when selecting that build. |
| App Privacy | Privacy policy exists in the app/site, but its ASC URL is empty. Publication state is not verifiable through the public API; the browser session expired during inspection. | Complete and publish the privacy answers in App Store Connect, consistent with actual collection and optional route behavior. |
| Public support | Support and privacy pages direct users to TestFlight feedback or the channel that supplied the beta. There is no general public contact method. | Add a monitored public support/privacy contact and connect it to ASC. Apple requires a support URL with a way to contact the developer. See [guideline 1.5](https://developer.apple.com/app-store/review/guidelines/#developer-information). |
| Physical sync completion | Prior evidence proves incremental real-data round trip and APNs receipt with the app open. It does not prove the full historical backfill, background completion, or force-quit fallback. | Complete all three on a release build; record completed timestamps, pending-work counts, and successful resume behavior. |
| End-user agent integration | Official MCP SDK OAuth/tool/decryption integration passes. The setup guide requires a client with private secrets and code execution. | Validate at least one named supported client's actual user workflow, including private key configuration, URL fetching, decryption, token refresh, and revocation. SDK success alone does not establish compatibility with every agent UI. |
| Supported device/accessibility range | Fresh native tests used iPhone 17 Pro / iOS 26.3.1 simulator. Deployment minimum is iOS 18. | Exercise the oldest supported OS, a smaller supported iPhone, large Dynamic Type, VoiceOver, offline recovery, and a large real HealthKit history. |

The 34 ASC checks are mostly missing submission configuration, including 24 age-rating fields; they are **not 34 additional code bugs**. The exact response is in [app-store-readiness.json](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/app-store-readiness.json). Review notes should explain the health-management use case, user consent, third-party AI sharing, and private sandbox workflow against Apple's [health-data and sharing guidelines](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research). App Review acceptance cannot be inferred from TestFlight processing.

**Two design decisions deserve an explicit launch decision.**

The key generator provides 80 random bits, as the spec and privacy policy already disclose; SHA-256 and AES-256 do not increase the entropy of that secret. I recommend at least 128 random bits for long-lived health data, with a versioned migration while the user base is small. This is a security-margin recommendation, not a demonstrated key-recovery exploit. [NIST's definition of security strength](https://csrc.nist.gov/glossary/term/security_strength) distinguishes attack work from a cipher's nominal key size.

The threat model includes a compromised Worker, yet reference decryption code and instructions are served by that same Worker for execution in a sandbox containing the secret. A client that executes modified helper code would lose the intended protection. The supported integration should use a trusted, pinned/client-owned decryption implementation and treat server-supplied source as untrusted. The current helper code itself contains no key transmission; the remaining issue is the distribution and execution trust boundary.

**Validation performed during this review**

| Check | Result |
|---|---|
| Worker/protocol TypeScript and site TypeScript | Both pass |
| Existing protocol tests | 3 pass |
| Existing native suite | 19 pass, zero failures/skips; [result bundle](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/native-baseline.xcresult) |
| Fresh isolated local integration | 21 checks pass: signed registration, replay rejection, cross-user isolation, OAuth/PKCE/refresh, six MCP tools, references, encryption/decryption, deletion, revocation, and rotation; [log](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/local-integration.log) |
| Crypto interoperability | Swift → Node, Swift → Python, and Node → Python pass |
| Marketing production build | Pass, all routes statically generated; [log](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/site-build.log) |
| Live read-only checks | 13 HTTP, helper parity, and Universal Link checks pass; [results](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/live-readonly-checks.json) |
| Current production dependency advisories | Zero reported vulnerabilities in both root and site `npm audit --omit=dev` results |
| New Worker failure/contract probes | Five observations reproduced against production functions with isolated SQLite/R2 adapters; [source](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/worker-fault-probes.ts) |
| New native observation probes | Four observations reproduced: concurrent sync while busy, repeated full-period rebuilds, restored preferences without identity, and failed-bootstrap retry; [source](/Users/iddogino/Dropbox/HealthMCP/artifacts/review-2026-09-08/native/apps/ios/HealthMCPTests/ReviewObservationsTests.swift) |

The observation probes deliberately assert the current defective behavior. Their passing results mean the issues were reproduced, not fixed. The first performance probe expected ten repeated reads and observed nine because the first pages coalesced; the final probe records the measured behavior without assuming one rebuild per page. Native probes ran in an isolated app bundle and Keychain namespace copied from the reviewed commit. No private health values or key were exported, no production accounts were created/deleted for this review, and no new release was uploaded or submitted.

**Recommended sequence:** first serialize privacy changes and repair upload/account/identity recovery; then remove repeated backfill work and bound background execution; then resolve workout/range/pairing correctness and enforce resource budgets. Run the failure regressions plus the full physical-device and supported-client gates on the resulting build before completing submission and widening distribution.
