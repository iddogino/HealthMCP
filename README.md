# Health MCP

A native iPhone app, encrypted Cloudflare cache, remote MCP server, and marketing site.

- Marketing and setup: https://healthmcp.cc
- Streamable HTTP MCP: https://mcp.healthmcp.cc/mcp
- Service health: https://mcp.healthmcp.cc/health
- iOS bundle: `cc.healthmcp.app`
- App Store Connect: **Health MCP: Private Sync**, app `6809625249`

The app reads Apple Health, encrypts each JSON chunk on the phone, and uploads ciphertext. An approved MCP client receives manifests and decrypts files in its own private code environment. The health key never goes to the Worker.

## Repository

| Path | Purpose |
|---|---|
| `apps/ios` | SwiftUI app, HealthKit readers, CryptoKit encryption, durable SQLite sync journal, native tests |
| `apps/worker` | Device authentication, encrypted R2 storage, D1 catalog, OAuth pairing, six MCP tools, APNs |
| `apps/site` | Static React/Vinext marketing, setup, privacy, and support pages |
| `packages/protocol` | Shared series catalog and Node/Python decryption helpers |
| `scripts` | Deployment validation, native crypto interoperability, device validation runner |
| `docs` | Original spec, wire decisions, operations, and validation evidence |

## Run locally

Requires Node 22.13+, npm, Xcode 26+, XcodeGen, Wrangler, and `asc` for Apple distribution. The iPhone app supports iOS 18+.

```sh
npm ci
npm --prefix apps/site ci
npx wrangler d1 migrations apply healthmcp-db --local --config apps/worker/wrangler.local.json
npm run dev
```

In a second terminal:

```sh
npm run dev:site
```

The local Worker listens on `http://localhost:8787`. Its checked-in signing secret is an explicit public test fixture. The native app uses the production domain; tests never inject fake data into a real HealthKit store.

Generate and open the iOS project:

```sh
npm run ios:generate
open apps/ios/HealthMCP.xcodeproj
```

The project uses automatic signing with the configured Apple team. Use your team and provisioning settings when adopting this repo elsewhere. Signing private keys and provisioning profiles are not committed.

## Validate

```sh
npm run typecheck
npm run typecheck:site
npm test
npm run test:e2e
```

Run the native `HealthMCP` test scheme in Xcode, or:

```sh
xcodebuild -project apps/ios/HealthMCP.xcodeproj -scheme HealthMCP \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Cross-language checks compile the actual Swift crypto implementation and decrypt its output in Node and Python:

```sh
python3 -m venv .venv
.venv/bin/pip install cryptography
npm run test:interop
```

Live validation creates and removes only its own synthetic accounts:

```sh
HEALTHMCP_BASE_URL=https://mcp.healthmcp.cc npm run test:e2e
HEALTHMCP_BASE_URL=https://mcp.healthmcp.cc HEALTHMCP_TEST_APNS=1 npm run test:e2e
```

The optional APNs probes use all-zero synthetic tokens. They validate the request path to Apple's sandbox and production endpoints; they do not prove delivery to an iPhone. See `docs/validation.md` for the separate real-device gate.

## Deploy

Cloudflare resources are declared in `apps/worker/wrangler.jsonc` and `apps/site/wrangler.site.jsonc`.

```sh
npx wrangler d1 migrations apply healthmcp-db --remote --config apps/worker/wrangler.jsonc
npm run deploy:worker
npm run deploy:site
```

Required Worker secrets:

- `BLOB_SIGNING_SECRET`: at least 32 random characters.
- `APNS_PRIVATE_KEY`: the production APNs P-256 private key, PEM format.
- `APNS_SANDBOX_PRIVATE_KEY`: the sandbox APNs P-256 private key, PEM format.

APNs key IDs, team, bundle ID, domains, and resource IDs are non-secret configuration. Keep the health decryption key entirely out of Worker secrets.

The site uses a separately named Wrangler configuration because Vinext's automatic Worker detection conflicts with its static export mode. It deploys static HTML/assets with no server rendering or application secrets. `.openai/hosting.json` records the static output; hosting is directly in the owner's Cloudflare account.

## Using the app

1. Choose Health read permissions.
2. Save the private key securely and acknowledge it.
3. Start the first historical backfill. Keep the app open for a large history.
4. Follow progress, pause/resume if needed, and review Sync history.
5. Add the MCP endpoint to a compatible client and approve its pairing code in Agents.
6. Configure `HEALTHMCP_KEY` in that client's private code environment, never in chat or tool arguments.

Optional data groups and GPS routes are controlled in Settings. Disabling them removes the corresponding encrypted copies. Key rotation revokes connections and rebuilds the cache. Account deletion removes active server data and local keys; Apple Health is unchanged.

## Current scope

V1 has read-only HealthKit access, individual agent revocation, resumable paginated backfills, four concurrent chunk uploads, sync history, on-device summaries, and best-effort background/push refresh. No analytics or advertising SDK is included.

V1's 16-character random key contains 80 bits of entropy, plus a checksum. AES-256 is the cipher, not a claim of 256-bit secret entropy. ECG and GPS are opt-in because payload size varies. Keys do not migrate to another phone; recovery means a new identity and backfill. iOS controls background execution and notification delivery.
