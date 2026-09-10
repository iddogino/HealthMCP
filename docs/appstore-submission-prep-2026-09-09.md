# App Store submission preparation — September 9, 2026

**Finalized September 10:** Version 1.0.0 (14) is now **Waiting for Review**, with Free pricing, the No medical-device declaration and published App Privacy. Release remains manual. See the [completed submission record](appstore-submission-2026-09-10.md). The preparation and pending-approval notes below are historical and were resolved during that finalization.

**September 10 build update:** [Build 14](evidence/appstore-build-14-2026-09-10.json) is uploaded, processed (`VALID`, `APP_STORE_ELIGIBLE`) and attached to the existing version 1.0.0 draft. It includes the [layered icon](app-icon.md) and corrects build 13's unintended iPad support to `UIDeviceFamily = [1]`. Signed archive/IPA checks and strict staging validation passed. The version remains unsubmitted with manual release; the prior privacy, price and medical-device approvals remain pending.

**The version is staged and remains unsubmitted. Three owner approvals are pending before the ASC setup can be called complete:** publication of App Privacy, the Free V1 price, and the medical-device declaration. No review submission exists; release remains manual.

[Open the prepared version](https://appstoreconnect.apple.com/apps/6809625249/distribution/ios/version/inflight).

## Saved and verified

| Item | Saved state |
| --- | --- |
| App and version | Health MCP: Private Sync, `6809625249`, version 1.0.0, `PREPARE_FOR_SUBMISSION` |
| Attached build | 14, `9db5eadd-b05c-4d65-8f9b-c4d83de8214a`, `VALID`, `APP_STORE_ELIGIBLE`, minimum iOS 18, iPhone only |
| Listing | English (US) description and promotional text updated; remote MCP and optional desktop connector are distinguished accurately |
| Screenshots | Five 1320 × 2868 screenshots replace the previous three; every asset is `COMPLETE`, with matching server checksum and size |
| Review details | Iddo Gino, support@healthmcp.cc, owner-provided private phone, no sign-in required, complete setup notes |
| Countries and regions | All 175 selected, available on release, including future territories; no pre-order or release |
| Platforms | Apple Silicon Mac and Apple Vision Pro availability disabled and checked after reload; V1 targets iPhone |
| Release | Manual; no `appStoreVersionSubmission` and an empty review-submission list |
| Age rating | Existing questionnaire complete: health/wellness topics, no medical/treatment information, social media or advertising; global 9+ with regional exceptions |
| Business | Free and Paid Apps Agreements Active; DSA Active; current app declaration says non-trader. No business classification was changed |
| Public contacts | Support page lists support@healthmcp.cc and privacy@healthmcp.cc; privacy page uses privacy@healthmcp.cc. Both live pages returned HTTP 200 |

The owner confirmed both mailboxes are set up. Google MX records resolve for the domain. Inbound message delivery was not independently tested; no email was sent.

## Pending approvals

| Item | Prepared state | Why it remains pending |
| --- | --- | --- |
| App Privacy publication | Seven categories saved, each for App Functionality, linked to account/device, without tracking | Apple's Publish dialog contains an explicit legal accuracy/compliance certification. The browser confirmation policy requires owner approval for that final certification |
| Download price | Free ($0.00) in all 175 regions was prepared; no price saved | Automatic approval review rejected advancing the price because the owner had not explicitly selected it. The price wizard was canceled to save the independent platform settings |
| Regulated medical device | Proposed answer: No | Apple shows a required declaration for this Health & Fitness app. Automatic approval review rejected selecting No without owner confirmation of the regulatory facts and authorization |

These approval requests are pending in the task. They do not authorize an App Review submission. After approval, save the relevant settings and read each back; do not click Add for Review or submit/release the app.

## Privacy disclosure basis

The saved App Privacy draft covers the end-to-end app and service. All categories use App Functionality, are linked to the assigned account/device, and are not used for tracking.

| Data type | Relevant behavior |
| --- | --- |
| Health | Readable HealthKit records and health-series metadata |
| Fitness | Activity, exercise and workout records |
| Precise Location | Optional workout routes, encrypted before upload |
| Sensitive Info | Optional reproductive records, including pregnancy-related data |
| User ID | Assigned pseudonymous account identifier |
| Device ID | Public device signing key and optional APNs token |
| Other Diagnostic Data | Operational request/error information and service security diagnostics |

The source review included `SeriesDefinition.swift`, `HealthReader.swift`, the worker registration/push/security paths, and Cloudflare observability configuration. Device/account linkage exists even without a name or email. Optional HealthKit groups remain disclosed because enabling them sends retained data to the service. Audio exposure is a measurement rather than a sound recording.

The binary's privacy manifest currently lists Health, Fitness, Precise Location and User ID. The broader ASC declaration also accounts for optional sensitive records, device identifiers and backend operations; this preparation did not rebuild or change the signed binary. The store declaration is not a claim that the manifest alone describes every backend data practice. [Apple's App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/).

## Validation and limits

`asc release stage --strict-validate` completed successfully after an inspected dry run. The September 9 preparation retained build 13; the September 10 follow-up attached build 14. Both reused the version, confirmed the metadata was already in sync and stopped before review submission. The latest strict staging validation reports **0 errors, 0 warnings and 2 informational notices**: manual release and App Privacy publication not verifiable through the public API. A separate readback confirmed build 14 is attached, release remains manual, and no review submissions exist.

The browser exposes required setup that this API report does not catch: no current download price and an unanswered medical-device declaration, alongside the unpublished privacy responses. These remain blockers in this preparation record despite the clean API report. Apple documents the declaration requirement for Health & Fitness apps in the selected regions. [Medical-device status declaration](https://developer.apple.com/help/app-store-connect/manage-app-information/declare-regulated-medical-device-status).

Site type checking and the production site build/deployment passed during the September 9 preparation. Cloudflare site version: `af520516-2f57-4160-bbe8-279454650886`. The September 10 follow-up rebuilt the app for the icon and device-family changes; it did not change app logic or backend behavior. The previous native/backend test results were not rerun. Icon compatibility checks, signed-package verification and Apple's successful processing are recorded in the build 14 evidence.

The earlier [readiness assessment](appstore-readiness-2026-09-09.md) still governs product and policy acceptance: full physical-device backfill/background validation, actual named-assistant acceptance, accessibility/operational checks, HealthKit/AI downstream use, and seller eligibility have no new completion evidence here. Active account agreements and a saved non-trader declaration do not establish legal-entity eligibility or resolve those policy questions. Worldwide selection likewise does not establish any region-specific regulatory eligibility.

## Evidence

Compact, non-secret results: [submission-preparation evidence](evidence/appstore-submission-prep-2026-09-09.json). Detailed API responses, staging checkpoints, screenshot checksums and deployment logs are under `artifacts/asc-submission-prep/`. The private review phone remains in App Store Connect and ignored local evidence, not checked-in documentation.

Canonical metadata is in `metadata/`; reviewer instructions are in [app-review-notes.md](app-review-notes.md). Screenshot capture/render/upload details are in [appstore-screenshots.md](appstore-screenshots.md).
