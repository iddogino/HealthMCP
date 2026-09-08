# Draft App Review notes

Health MCP is a read-only connection between a user's Apple Health history and the health/fitness assistant they choose. It does not provide diagnosis or treatment and never writes or deletes Apple Health records.

No username, password, paid purchase or demo login is required. Onboarding registers a device signing identity, asks for read-only HealthKit access, presents a device-generated private key and starts a resumable encrypted sync. Reviewers may share any supported data available on their own test device, or deny permissions; an empty Health store is handled without a false permission claim.

Optional nutrition, reproductive health, symptoms, audio, ECG and GPS route groups are off by default. Users explicitly approve each client after seeing its name, callback host, shared groups, route status, and disclosure that the connected third-party AI provider receives the requested decrypted records under that provider's own terms.

To test the desktop integration, export the trusted client from Settings and transfer the ZIP to a computer with Node.js 22 or newer. Follow its README to run connect, approve the displayed code in Agents, privately configure the key and run check. Add the client as a local stdio MCP server to a compatible assistant. Do not place the key in chat. The remote service does not possess the key. Reference code is included in the signed iPhone app; the client never executes source supplied by the remote server.

Settings provides individual connection revocation, optional-data removal, key rotation and account/cache deletion. Previously downloaded third-party copies cannot be recalled. Background refresh and notifications are best effort under iOS; a first historical backfill works best with the app open and the phone charged.

Support and privacy contact: support@healthmcp.cc. Private review contact: Iddo Gino; phone number pending owner input. Publish these notes only after completing that contact and verifying support email delivery.
