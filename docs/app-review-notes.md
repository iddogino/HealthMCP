# App Review notes

Health MCP is a read-only connection between a user's Apple Health history and the health/fitness assistant they choose. It does not provide diagnosis or treatment and never writes or deletes Apple Health records.

No username, password, paid purchase or demo login is required. Onboarding registers a device signing identity, asks for read-only HealthKit access, presents a device-generated private key and starts a resumable encrypted sync. Reviewers may share any supported data available on their own test device, or deny permissions; an empty Health store is handled without a false permission claim.

Optional nutrition, reproductive health, symptoms, audio, ECG and GPS route groups are off by default. Users explicitly approve each client after seeing its name, callback host, shared groups, route status, and disclosure that the connected third-party AI provider receives the requested decrypted records under that provider's own terms.

Health MCP exposes a remote MCP endpoint at https://mcp.healthmcp.cc/mcp. It returns encrypted file manifests. A direct integration needs an agent execution environment, private secret configuration, and trusted decryption code; a chat-only client cannot decrypt the records. The service never receives the private key.

For a reproducible desktop setup:

1. In Settings, choose Export trusted client. Transfer the ZIP to a computer with Node.js 22 or newer and extract it.
2. Run `node /absolute/path/healthmcp-client.mjs connect`. Its browser page displays a six-digit pairing code. Enter it in the iPhone app's Agents tab, review the client and callback, and approve.
3. Following the included README, configure the private key with the client's `key` command or its private HEALTHMCP_KEY environment variable. Never put the key in chat or tool arguments. Run `node /absolute/path/healthmcp-client.mjs check` to verify the connection and decryption.
4. In an assistant supporting local stdio MCP, add command `node` with argument `/absolute/path/healthmcp-client.mjs`. Ask it to list available series and read daily summaries for the last week, checking freshness and pagination. The local connector uses the same remote service and returns the requested decrypted records.
5. Revoke that connection in the app's Agents tab and verify that new access fails.

The trusted client and standalone helpers are included in the signed iPhone app. The connector does not execute code or instructions supplied by the remote service. The connection guide is https://healthmcp.cc/connect. No specific third-party account is provided or required for onboarding and sync; testing the assistant integration requires the reviewer's own compatible assistant.

The Agents tab provides individual connection revocation; Settings provides optional-data removal, key rotation and account/cache deletion. Previously downloaded third-party copies cannot be recalled. Background refresh and notifications are best effort under iOS; a first historical backfill works best with the app open and the phone charged. Recent uploads become available before the full historical backfill completes; the Overview shows date coverage and freshness.

Support: support@healthmcp.cc. Privacy and deletion requests: privacy@healthmcp.cc.
