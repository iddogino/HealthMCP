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

The app commits HealthKit query anchors, sample identifiers, and dirty chunk markers together in SQLite. An interrupted upload leaves the dirty marker in place. A successful upload removes it. Each HealthKit page is limited to 1,000 records; up to four chunks upload concurrently. Each failed upload gets up to three attempts, and remaining failures are saved in history.

Logical object paths remain stable as AES-GCM additional authenticated data. Physical R2 objects include a cache generation: `<user>/g<generation>/<series>/<period>.enc`. Reset/revocation gates every MCP request and download using D1. An old upload cannot overwrite the new generation after rotation.

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

The app's encryption is provided by Apple CryptoKit, Security, and URLSession. `ITSAppUsesNonExemptEncryption` is false based on Apple's [operating-system encryption documentation rule](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/). No third-party encryption implementation is linked into the iOS app.

No public App Store review submission or external beta rollout is performed by this setup.
