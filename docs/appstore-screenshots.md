# App Store screenshot artwork

Five English (US) screenshots are uploaded to the Health MCP 1.0.0 (13) draft. The PNGs under `artifacts/appstore-listing-2026-09-09/framed/en-US/` are the 6.9-inch iPhone set. `preview.png` is a contact sheet for review, not an upload asset. The project targets iPhone only.

The images retain the app's actual UI and use fictional simulator fixtures. The wrappers add headlines, background colors, and a matching iPhone frame. The captions avoid diagnosis, guaranteed background sync, and unsupported assistant compatibility claims.

Health MCP is a remote service. The first image says “Encrypted cloud sync. Connect through MCP.” The bundled desktop connector shown in Settings runs locally to decrypt data; local MCP support is specific to that connector. Direct remote integrations need a trusted execution environment, private key configuration, and trusted decryption code.

## Rebuild the wrappers

Run from the repository root:

```sh
python3 -m venv artifacts/appstore-shots-venv
artifacts/appstore-shots-venv/bin/pip install koubou==0.18.1
artifacts/appstore-shots-venv/bin/kou setup-frames
artifacts/appstore-shots-venv/bin/python scripts/render-store-listing.py
asc screenshots validate --path artifacts/appstore-listing-2026-09-09/framed/en-US --device-type IPHONE_69 --output table
asc screenshots review-generate --framed-dir artifacts/appstore-listing-2026-09-09/framed --raw-dir artifacts/appstore-listing-2026-09-09/review-raw --output-dir artifacts/appstore-listing-2026-09-09/review
```

The renderer runs each image separately to bound Koubou's memory use. Design source is `.asc/store-listing.yaml`; the contact sheet is `.asc/store-preview.yaml`. Native macOS Arial fonts are used. `--preview-only` rebuilds just the contact sheet. The script records output/source SHA-256 hashes in `manifest.json`.

The asc local capture/framing workflow is experimental. Current dimensions were checked with both `asc screenshots sizes --all` and Apple's published screenshot specification. Final files are opaque RGB PNGs. Regeneration preserves the original raw captures.

## Capture provenance

Simulator: iPhone 17 Pro Max, iOS 26.3, 1320 × 2868. App build: 13, Debug, using the existing `-ui-testing` fixture entry point. The Release build does not enable these fixtures. The simulator status bar was standardized to 9:41, full Wi-Fi/cellular bars, and full battery. No physical-device health store was accessed for screenshot generation.

| Capture | Setup |
| --- | --- |
| `01-overview.png` | Launch `-ui-testing`; completed overview |
| `02-recent-first.png` | Launch `-ui-testing -ui-syncing`; ready recent coverage and historical progress |
| `03-sharing.png` | Settings, scroll until everyday health plus optional groups/routes are visible |
| `04-approve-agent.png` | Launch `-ui-testing -ui-pairing`; enter fictional code `483921` and review Demo Agent consent |
| `05-private-client.png` | Settings, top of the page, after the tab animation settles |

Sources live under `artifacts/appstore-listing-2026-09-09/raw/`. Full-resolution images were captured with `simctl`; XcodeBuildMCP's optimized screenshots were too small for upload. Simulator gestures used the screenshot skill's AXe tools. Matching copies under `review-raw/en-US/` enable the asc side-by-side review.

The App Store localization is `8172bf40-184b-48cc-90e0-d9e38be214b8`. On September 9, 2026, the previous three images were replaced with this five-image sequence in set `be6c7386-d687-4657-ade5-920b71d38de2`. All five have delivery state `COMPLETE`; the server checksums and file sizes match the local PNGs. App Store Connect displays five screenshots in the expected order. No App Review submission was created.

Upload and readback evidence is under `artifacts/asc-submission-prep/`, including `screenshots-verified.json`. The screenshot ZIP and its manifest now record the completed upload. See [submission preparation](appstore-submission-prep-2026-09-09.md) for the remaining draft setup.
