# App Store submission — September 10, 2026

Update: the original build-14 submission below was replaced by [build 17 at 14:09 PDT](appstore-build-17-2026-09-10.md), which is now Waiting for Review.

**Health MCP: Private Sync 1.0.0 (14) is submitted and Waiting for Review.** Apple accepted the submission at 09:23:52 PDT on September 10, 2026. Release remains manual after approval; the app has not been released.

[Open the submitted version](https://appstoreconnect.apple.com/apps/6809625249/distribution/ios/version/inflight).

| Item | Verified state |
| --- | --- |
| App | `6809625249`, `cc.healthmcp.app` |
| Version | `5806847e-2cd2-47c1-a26f-be83e82453f4`, 1.0.0, `WAITING_FOR_REVIEW` |
| Build | 14, `9db5eadd-b05c-4d65-8f9b-c4d83de8214a`, with the layered icon and iPhone-only configuration |
| Review submission | `d2b17e81-c272-4e1b-bb33-fd4a18217344`, `WAITING_FOR_REVIEW` |
| Price | Free in all 175 App Store territories |
| Availability | All 175 territories enabled; future territories included |
| Medical-device declaration | No, as explicitly confirmed by the owner; saved and verified in ASC |
| App Privacy | Published; seven categories used for App Functionality, linked to account/device, without tracking |
| Privacy policy | `https://healthmcp.cc/privacy`, saved in ASC and verified live |
| Screenshots | Five complete screenshots; checksums match the prepared listing |
| Release | Manual after approval |

The final strict API preflight passed with zero errors and zero warnings. Its two informational notices concern manual release and the public API's inability to verify privacy publication. Publication was separately confirmed in the browser by Apple's “Published a few seconds ago by Iddo Gino” status.

## Privacy clarification

Automatic approval review initially rejected publication because it interpreted the policy's default-off GPS setting and location-free catalog as conflicting with the Precise Location disclosure. Source inspection confirmed that enabled HealthKit workout routes include precise coordinates, are encrypted before upload, and are retained as encrypted files associated with the account. The app's existing privacy manifest also declares precise location for app functionality.

The policy now explicitly describes optional GPS/reproductive uploads and distinguishes encrypted account files from the unencrypted catalog, which contains no precise coordinates. Site type checking and the production build passed; the clarification was deployed and verified live before retrying privacy publication successfully. Cloudflare site version: `f1f8b89b-3551-4aa5-9195-81e9d4dea6bd`.

The label continues to include optional data types because they can be synced after permission. Apple's guidance distinguishes a feature being optional from satisfying all optional-disclosure criteria. [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/).

## Submission verification

The high-level CLI created the review packet and version item but stopped on its own final relationship check. Separate API reads confirmed that the existing packet contained exactly the intended version and build. Submitting that same packet succeeded, and subsequent API reads confirmed both the version and submission were `WAITING_FOR_REVIEW`.

No iOS binary or backend behavior changed during this finalization. Previous build and runtime validation remains recorded in [build 14 evidence](evidence/appstore-build-14-2026-09-10.json); native/backend tests were not rerun. Submission acceptance does not mean Apple has approved the app.

Evidence: [final submission](evidence/appstore-submission-2026-09-10.json), [privacy verification](evidence/privacy-publication-verification-2026-09-10.json). Detailed API responses and deployment logs are under `artifacts/asc-submission-2026-09-10/`.
