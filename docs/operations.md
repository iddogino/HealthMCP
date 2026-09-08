# Operations

## Provisioned resources

| Resource | Identifier |
|---|---|
| Cloudflare account | `5f22bc2f89d05868489db974851f2bd1` |
| API Worker | `healthmcp-api` |
| Marketing Worker assets | `healthmcp-site` |
| D1 | `healthmcp-db` / `48f345cb-4704-4095-bc2e-42853ea91dd4` |
| Private R2 | `healthmcp-encrypted` |
| OAuth KV | `healthmcp-oauth` / `cb95c9974c6d4d5496efed51a3ca90a7` |
| Apple team | `HL9SP7TJ3J` |
| Bundle | `cc.healthmcp.app` / `ZH43M6CA8Q` |
| App Store Connect app | `6809625249` |
| Sandbox APNs key | `H2F7LMNCSX`, topic `cc.healthmcp.app` |
| Production APNs key | `4P92YGPR7L`, topic `cc.healthmcp.app` |
| Internal TestFlight group | `0fc3d902-3ce6-466b-88cc-7f746f9d70dc` |

Both APNs private keys are Worker secrets, and their original downloads have owner-only file permissions. Back up those credentials securely; Apple permits each private key to be downloaded once. The encrypted health cache and the signing credentials are independent: the service never has the user's health key.

## Sync and recovery

The app commits HealthKit query anchors, sample identifiers, and dirty chunk markers together in SQLite. An interrupted upload leaves the dirty marker in place. A successful upload removes it and queues durable catalog publication. Each HealthKit page is limited to 1,000 records; up to four chunks upload concurrently between pages. Recent periods are seeded first, and successfully uploaded series become available through MCP before enumeration finishes. Each failed upload gets up to three attempts, and remaining failures are saved in history.

The sync engine, HealthKit readers, and journal use background actors. Main-actor progress updates are throttled, prepared SQLite statements are reused, and HealthKit queries have cancellation and a 90-second timeout. Build 4 migrates the existing journal without resetting anchors or the private key. See [sync performance](sync-performance.md) for measurements and restart tests.

During an active sync, the dashboard fetches current series and encrypted-cache totals every five seconds, independently of the upload pipeline. This loop reads only `/v1/status`, stops when the run ends, and finishes with a refresh after successful runs. Cancellation stops pending status requests promptly. The action label reserves and caps its text at two lines so stage changes do not move the controls below it.

Logical object paths remain stable as AES-GCM additional authenticated data. Physical R2 objects include a cache generation and unique version suffix: `<user>/g<generation>/<series>/<period>.enc.<uuid>`. Reset/revocation gates every MCP request and download using D1. An old upload cannot overwrite the new generation after rotation.

A sync request is throttled independently of upload completion to one per 15 minutes. A one-minute cron checks requests older than two minutes for a visible fallback. A health-data upload or completed sync cancels that pending fallback; a startup key-check or profile upload does not. APNs JWTs are cached across Worker cold starts for 50 minutes. Push acceptance is not proof that iOS ran the app.

If iOS locks access to HealthKit, sync pauses with one recovery message and keeps anchors and pending chunks intact. Opening the app after unlocking resumes. The screen stays awake during foreground sync, including after returning from a system prompt.

The HealthKit observers, scheduled background task, foreground entry, and APNs delegate share the same app model, including during a background launch. HealthKit and the Keychain remain subject to device lock protection. Force-quitting prevents background delivery until the app is opened again.

## Apple distribution

`asc` uses the existing App Store Connect keychain profile. Archive/export use automatic provisioning. Build numbers are in `apps/ios/project.yml`; regenerate the Xcode project after changing them.

```sh
asc builds next-build-number --app 6809625249 --version 1.0.0 --platform IOS
asc xcode archive --project apps/ios/HealthMCP.xcodeproj --scheme HealthMCP \
  --configuration Release --archive-path artifacts/HealthMCP.xcarchive \
  --xcodebuild-flag=-destination --xcodebuild-flag=generic/platform=iOS \
  --xcodebuild-flag=-allowProvisioningUpdates
asc xcode export --archive-path artifacts/HealthMCP.xcarchive \
  --ipa-path artifacts/HealthMCP.ipa --team-id HL9SP7TJ3J \
  --xcodebuild-flag=-allowProvisioningUpdates
asc builds upload --app 6809625249 --ipa artifacts/HealthMCP.ipa --wait
```

Build 1 was rejected by Apple's binary processing for a missing `NSHealthUpdateUsageDescription`, even though the app requests an empty write-permission set. Build 2 adds an accurate read-only explanation. The app never calls HealthKit save/delete APIs.

The app's encryption is provided by Apple CryptoKit, Security, and URLSession. `ITSAppUsesNonExemptEncryption` is false based on Apple's [operating-system encryption documentation rule](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/). No third-party encryption implementation is linked into the iOS executable. The exported desktop client and reference helpers are bundled as resources; they use Node/Python cryptography on the computer, never execute inside the iOS app, and remain subject to their platforms’ export requirements.

No public App Store review submission or external beta rollout is performed by this setup.

## Build 9 recovery and storage limits

Before an upgrade, record a D1 Time Travel bookmark with `npx wrangler d1 time-travel info healthmcp-db --config apps/worker/wrangler.jsonc`. Apply migrations 0003 and 0004 before deploying the Worker. They support legacy writes during the handoff. Do not roll the Worker back to its old fixed-object uploader after new uploads have begun; it does not understand the new physical versions.

New uploads reserve physical storage atomically before writing R2. Quota includes current, pending, and retained old versions. A failed D1 publication preserves the prior version and retries safely. The one-minute scheduled job cleans up unreferenced versions and performs a bounded, one-time walk of the old bucket. Ambiguous writes remain charged for at least one hour before cleanup; a large legacy bucket can take multiple hours to reconcile. Logical cache totals are maintained separately in constant-time counters.

Default limits (positive integer Worker vars can override them):

| Limit | Default | Variable |
|---|---|---|
| Account encrypted storage | 2 GiB / 500,000 objects | `MAX_USER_BYTES`, `MAX_USER_OBJECTS` |
| Global physical storage | 100 GiB / 5,000,000 objects | `MAX_GLOBAL_BYTES`, `MAX_GLOBAL_OBJECTS` |
| Active accounts | 1,000 | `MAX_ACCOUNTS` |
| Upload/delete-chunk requests per minute | 600/account; 6,000 global | `MAX_USER_WRITES_PER_MINUTE`, `MAX_GLOBAL_WRITES_PER_MINUTE` |

Additional device, MCP, download, registration, OAuth-client, and pairing limits apply. Storage exhaustion returns 507 without accepting a new upload; throttles return 429 with Retry-After. Account/series cleanup stays available at storage capacity. No device attestation is claimed. These controls bound admitted application work but do not cap all Cloudflare charges or replace platform DDoS protection.

Inspect `quota_usage` for physical consumption, `cache_usage` for published logical consumption, and `storage_maintenance` for the one-time migration scan. The regression deployment verified both counter sets against their source tables. Worker observability is enabled; billing alerts and an operator notification destination still need account-level configuration before widening distribution. Do not log private health values, signed download URLs, OAuth tokens, or health keys.

Privacy operations persist in the device Keychain before cancellation or network work. A failed cleanup remains visibly pending and blocks sync until retried. Rotation uses an operation ID, and all new sync requests bind to a generation and privacy revision. Deletion receipts retain only the old account ID and signing public key for 30 days so lost successful responses can be retried. Confirmed device cleanup removes the durable operation last.

The trusted desktop client must be rebuilt with `npm run build:client` before making an iOS release that changes its source or dependencies. The exact ZIP ships in the signed app. See [client setup](../packages/client/README.md) and [release fix evidence](release-fixes-2026-09-08.md).
