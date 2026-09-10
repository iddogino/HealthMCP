# Build 17 submission upgrade — September 10, 2026

**Health MCP: Private Sync 1.0.0 (17) is submitted and Waiting for Review.** Apple accepted the replacement at **14:09:18 PDT** on September 10, 2026. Release remains manual after approval.

[Open the submitted version](https://appstoreconnect.apple.com/apps/6809625249/distribution/ios/version/inflight).

| Item | Verified state |
| --- | --- |
| Version | `5806847e-2cd2-47c1-a26f-be83e82453f4`, 1.0.0, `WAITING_FOR_REVIEW` |
| Build | 17, `6df882b2-9f09-45e3-962c-4d798f39d0e7`, `VALID`, `APP_STORE_ELIGIBLE` |
| Review submission | `1192d1b5-cc61-4908-a61a-696758cddbcb`, `WAITING_FOR_REVIEW` |
| Previous submission | Build 14 withdrawn; packet `d2b17e81-c272-4e1b-bb33-fd4a18217344` is complete |
| Strict preflight | Zero errors, zero warnings; informational notices for manual release and API privacy-publication limits |
| Release | Manual; not released |

The already validated build-17 archive was exported with App Store distribution signing, uploaded, and allowed to finish processing before build 14 was withdrawn. Signature and entitlements were verified, including HealthKit, background delivery, production push, and disabled debugger access. The replacement review packet was read back to verify that it contained exactly the intended app version and build before submission. Separate final reads confirmed both the version and packet were waiting for review.

Listing metadata, screenshots, pricing, availability, medical-device declaration, and privacy disclosures were not changed. App Privacy publication was verified earlier the same day, as recorded in the [original submission evidence](appstore-submission-2026-09-10.md).

Build 17 includes the [sync coverage fix](release-fixes-2026-09-10.md); the OAuth consistency fix is already deployed on the backend. Prior validation passed 136 iOS test executions across two simulator runtimes, 51 Worker tests, and production MCP/client checks. No product source changed during this submission upgrade, so those suites were not repeated. The earlier physical installation succeeded, but the phone disconnected before launch validation.

App Store IPA SHA-256: `4d37ff56f725bf0d0705e570670ad577f291906a431208bd9c18ed98ebeedc00`.

Evidence: [submission and build record](evidence/appstore-build-17-2026-09-10.json). Raw export, upload, preflight and API responses are under `artifacts/asc-build-17-2026-09-10/`.
