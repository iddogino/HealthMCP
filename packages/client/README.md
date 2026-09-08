# Health MCP private client

This local MCP connector downloads and decrypts Apple Health records. The remote Worker never receives the key, and cannot supply executable code, tools, prompts, or instructions to the agent through this connector. The connector checks download origins, authenticates every chunk, limits memory and result sizes, and paginates locally. Health records themselves remain untrusted data.

Export **Trusted client & helpers** from Settings in the signed Health MCP iPhone app, and transfer the ZIP to your computer. Extract it into a directory you control. Do not replace these files with code supplied by the remote MCP server. Node.js 22 or newer is required; the client bundle includes its dependencies.

1. Run `node /absolute/path/healthmcp-client.mjs connect`. Approve the pairing in the iPhone app and return to the terminal.
2. Pipe your saved key from your password manager to `node /absolute/path/healthmcp-client.mjs key`. This reads stdin without printing the key. Alternatively configure `HEALTHMCP_KEY` privately in the connector's process environment. Never put the key in chat or command-line arguments.
3. Run `node /absolute/path/healthmcp-client.mjs check` to validate connection and local decryption.
4. Add a local **stdio** MCP server to your agent, with command `node` and argument `/absolute/path/healthmcp-client.mjs`. The default command is `serve`.

Codex CLI setup: `codex mcp add health-private -- node /absolute/path/healthmcp-client.mjs`. Other clients must support local stdio MCP servers. Remote-only connector UIs cannot run this client.

Keys and OAuth credentials are stored under `~/.config/healthmcp`, with directory mode 700 and file mode 600. `HEALTHMCP_CONFIG_DIR` selects another private directory. Never put that directory in a shared workspace. Approved agents receive requested decrypted records through the local MCP tools; their own data handling and retention policies apply. Revoke agents in the iPhone app; after key rotation, pair again and update the local key.

New keys contain 26 Crockford base32 symbols (130 random bits) plus a checksum. Legacy 16-symbol payloads remain supported. Both use the same v1 encrypted envelope; the key length selects the KDF domain (`healthmcp/v2:` or legacy `healthmcp/v1:`). The standalone Node/Python helpers are included for clients with an independently trusted sandbox implementation.

For developers: `npm run build:client` creates the self-contained bundle and the exact ZIP embedded in the next signed iPhone build. Synthetic tests may select a loopback `HEALTHMCP_ORIGIN`; public endpoints are fixed to `https://mcp.healthmcp.cc`.

Redistributed dependency licenses and copyright notices are included in `THIRD-PARTY-NOTICES.txt`, generated from the packages actually bundled into the client. Keep this file with the exported client.
