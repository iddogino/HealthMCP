# App Store submission assessment — September 9, 2026

**Recommendation: finish the submission setup and the remaining device/client checks before submitting build 13.** The current automated checks are clean, but App Store Connect still reports two blocking setup errors. App Privacy publication is unverified, and the published support address has no MX records. There is no recorded full historical backfill/background validation or named-assistant acceptance run for this release.

This assessment covers **Health MCP: Private Sync**, version **1.0.0 (13)**, app `6809625249`, build `83c7d5c4-0145-4d2b-addf-9ae37a315691`, and prepared version `5806847e-2cd2-47c1-a26f-be83e82453f4`. No application code, production service, distribution scope, or submission state changed during this assessment.

## Current evidence

| Area | Result | Evidence and limit |
| --- | --- | --- |
| App Store build | **Pass** | Apple reports `VALID` and `APP_STORE_ELIGIBLE`. Build 13 is attached to the version in `PREPARE_FOR_SUBMISSION`. Release remains manual. |
| iPhone 17 Pro / iOS 26.3 | **51 passed**, zero failed or skipped | Fresh full native suite, including seven UI tests, recovery, privacy, incremental sync, and local dates. |
| iPhone SE 3 / iOS 18.1 | **51 passed**, zero failed or skipped | Fresh full native suite on the oldest installed supported runtime and small screen. |
| Worker, protocol, local MCP client | **29 passed**, zero failed | Fresh regression suite for storage, authorization, quotas, deletion, OAuth recovery, range behavior, and client contracts. |
| TypeScript | **Pass** | Backend/protocol and marketing-site type checks. |
| Production dependency audit | **0 reported vulnerabilities** | Current `npm audit --omit=dev` for the root/backend/client dependency tree. This is an advisory scan, not a security guarantee. |
| Signed desktop-client resource | **Pass** | Build 13's embedded ZIP is byte-identical to the tested source resource. All five listed payload checksums verify; third-party notices are included. |
| Public service entry points | **Pass** | Homepage, support, privacy, connection guide, and OAuth discovery returned HTTP 200 in fresh curl checks. |
| Device install | **Pass, earlier today** | Signed build 13 installed and launched on the owner's iPhone 17 Pro; installed version was read back. The owner subsequently confirmed the UI looks good. |
| Store images | **5 ready** | New 1320 × 2868 RGB PNGs, no alpha, zero size/duplicate warnings; all five visually reviewed. These are local assets, not yet uploaded. |

Native result paths and counts are recorded in [appstore-native-2026-09-09.json](evidence/appstore-native-2026-09-09.json). Fresh CLI/HTTP evidence is under `artifacts/appstore-readiness-2026-09-09/`. The eleven prior code-review findings have fixes and regression coverage documented in [release-fixes-2026-09-08.md](release-fixes-2026-09-08.md); this assessment does not claim a second exhaustive security audit.

## Submission blockers and missing setup

| Priority | Item | Current evidence | Action needed |
| --- | --- | --- | --- |
| Blocking in ASC | App Review details | `review_details.missing` | Add the private review contact, including phone number, and the review instructions in [app-review-notes.md](app-review-notes.md). |
| Blocking in ASC | Country availability | `availability.missing` | Choose launch countries and initialize availability. Check Mac/Vision availability against the iPhone-only product scope. |
| Required verification | App Privacy | `privacy.publish_state.unverified`; CLI web session expired and browser redirected to login | Inspect and publish accurate privacy answers in App Store Connect. The bundled privacy manifest does not establish that the store declaration is published. Reconcile health, fitness, optional precise location, identifiers, and service metadata with actual collection and sharing. |
| Launch blocker | Working support/privacy email | `healthmcp.cc` MX lookup returned `NOERROR` with zero answers | Configure `support@healthmcp.cc` with a mailbox or forwarding destination, then verify actual inbound delivery. No test email was sent in this assessment. |

The validator reports **2 errors, 0 warnings, and 2 informational notices**. Besides privacy, the other notice is manual release, which is intentional. Existing metadata, category, content rights, age rating, pricing, attached build, export-compliance state, and the three previously uploaded screenshots produce no additional validator errors. The build declares exempt encryption; that is Apple's reported submission state, not an independent export-classification ruling.

The App Store Connect browser login request is pending. Account agreements, seller enrollment type, and trader verification were not established by the public API checks. Trader status still needs a declaration, with additional verification where EU distribution applies. [Apple's trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/).

## App Review risks worth resolving

**HealthKit sharing with AI needs a clear, defensible scope.** The app has explicit pairing consent and explains third-party AI disclosure, local decryption, and revocation limits. Confirm that the supported provider configuration and user guidance restrict downstream use appropriately; general provider terms alone are not evidence of equal protection. Apple's health-data and AI-sharing rules make this the principal policy risk. [App Review Guidelines, 5.1.1–5.1.3](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research).

**Confirm seller eligibility.** Guideline 5.1.1(ix) addresses legal-entity submission for apps requiring sensitive information. The privacy page currently names Iddo Gino as operator; that does not prove the account's enrollment type. Establish the appropriate submitting entity before review. This is an unresolved eligibility question, not a confirmed rejection. [App Review Guidelines, 5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage).

**Make the reviewer workflow concrete.** The core integration needs another computer, Node.js 22+, and an assistant supporting local stdio MCP. Supply exact export/pair/key/check steps and a short demonstration with synthetic data. Confirm the reviewer can exercise the app when their Health store is empty. [Apple's submission guidance](https://developer.apple.com/app-store/review/guidelines/#before-you-submit).

## Remaining product acceptance checks

1. **Large physical HealthKit history:** finish a full backfill on the release build, measure elapsed time and memory, and verify lock/background resume plus force-quit notification fallback. Simulator fixtures and successful installation do not establish these outcomes.
2. **One named assistant:** record a complete setup from the ZIP exported by build 13 through pairing, local key setup, a health-related query, pagination/freshness, and revocation. The existing production SDK-harness test is strong integration evidence, but is not this actual assistant workflow.
3. **Accessibility and operations:** finish a manual VoiceOver pass, verify operator/billing alert delivery and cleanup monitoring, and reconcile the remaining historical storage sweep. These previously documented checks have no newer completion evidence.
4. **Launch copy:** when the public release is ready, update the site's private-beta messaging and public download link. Keep the listing explicit about the desktop/local-MCP requirement and best-effort background refresh.

Earlier production evidence remains useful: 21 local and 21 live API/MCP checks, the packaged-client production harness, Swift/Node/Python crypto interoperability, a real HealthKit round trip, and foreground APNs receipt. See [release fixes](release-fixes-2026-09-08.md), [device round trip](evidence/device-roundtrip.json), and [validation](validation.md) for exactly what those runs established.

## New screenshot set

The five images use real build-13 UI with fictional simulator state, large headlines, alternating navy/mint backgrounds, and matching iPhone frames. No private health records, working credentials, or real encryption keys appear.

| Order | Headline | Actual screen |
| --- | --- | --- |
| 1 | Apple Health. For your agents. | Completed-sync overview and ready range |
| 2 | Recent data first. Start using it now. | Usable recent coverage while history continues |
| 3 | Your health data. Your choice. | Optional sharing groups and route controls |
| 4 | Every connection. Your permission. | Explicit consent for a fictional Demo Agent |
| 5 | Encrypted on iPhone. Opened by you. | Key storage and exportable trusted client |

The **6.9-inch iPhone** assets are **1320 × 2868 PNGs** with no transparency. This app targets iPhone only. Apple's current size table supports this set and scaling to smaller iPhone displays. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

Files: `artifacts/appstore-listing-2026-09-09/framed/en-US/`. Preview: `artifacts/appstore-listing-2026-09-09/preview.png`. The side-by-side source review has five matched raw captures and zero invalid sizes. Local screenshot automation in asc is experimental; the actual outputs were independently checked with `sips`, `asc screenshots validate`, and visual inspection. Generation instructions and the pinned renderer are in [appstore-screenshots.md](appstore-screenshots.md).

The existing three plain screenshots remain in the App Store draft. The new five-image set is generated and validated locally for the listing. No screenshot upload, App Review submission, or public release occurred.
