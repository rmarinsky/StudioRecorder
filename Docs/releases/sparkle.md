# Production releases and Sparkle updates

## Implemented contract

- Production bundle: `ua.com.rmarinsky.studiorecorder`, macOS 26+, arm64.
- Sparkle 2.10.0 is pinned through Swift Package Manager.
- Stable feed: `https://github.com/rmarinsky/StudioRecorder/releases/latest/download/appcast.xml`.
- Each stable release contains one full ZIP, its SHA-256 checksum, and a signed `appcast.xml` with embedded release notes. Archive URLs point to their immutable `vX.Y.Z` release.
- Both the ZIP and feed use the same app-specific Ed25519 key. The public key is embedded at build time; the private seed stays in Keychain and GitHub Secrets.
- Automatic checks require the user's Sparkle consent. Installing an update requires confirmation. System profiling is disabled.
- Recording (including pause and closure), streams, pending/running jobs, recovery, and active editor/GIF output delay installation. A native termination guard also protects resumed Sparkle installations that skip the usual postponement callback.
- Debug/DEV builds never start the production updater. Production and DEV have separate permissions and preferences.

The first Sparkle-enabled production build must be installed manually. An older build without Sparkle cannot discover it. Copy the app into Applications before running it.

## One-time GitHub configuration

Configure these on **rmarinsky/StudioRecorder**. Do not commit signing material or paste private keys into chat, issues, release notes, or logs.

| Name | Type | Value |
|---|---|---|
| `APPLE_TEAM_ID` | Variable | Apple developer team identifier |
| `SPARKLE_PUBLIC_KEY` | Variable | Base64 public key from `generate_keys` |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Secret | Base64 export of a Developer ID Application certificate and its private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Secret | Password for that P12 export |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Secret | Base64 P8 key permitted to use `notarytool` |
| `APP_STORE_CONNECT_KEY_ID` | Secret | ID of that API key |
| `APP_STORE_CONNECT_ISSUER_ID` | Secret | API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Secret | Base64 **32-byte seed** exported by current `generate_keys`; do not encode it again |
| `GOOGLE_OAUTH_CLIENT_ID` | Optional variable | Application-owned desktop OAuth client ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Optional secret | Matching desktop OAuth client secret |

Both Google values must be present to enable managed YouTube. Otherwise the release clears both and keeps recording/manual RTMPS available. Rotate any previously exposed OAuth client secret before distributing it.

### Create the Sparkle key once

Resolve the package and use the tools from the pinned dependency:

```sh
xcodebuild -resolvePackageDependencies -project StudioRecorder.xcodeproj \
  -scheme StudioRecorder -derivedDataPath build/releases
SPARKLE_TOOLS_DIR="$PWD/build/releases/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_TOOLS_DIR/generate_keys" --account StudioRecorder
"$SPARKLE_TOOLS_DIR/generate_keys" --account StudioRecorder -p
```

Use the printed public key for `SPARKLE_PUBLIC_KEY`. Keep the Keychain item and an encrypted recovery backup. Reuse this account for every release.

Export the seed only for secure transfer to GitHub Secrets:

```sh
umask 077
studio_key_dir="$(mktemp -d)"
"$SPARKLE_TOOLS_DIR/generate_keys" --account StudioRecorder -x "$studio_key_dir/sparkle-seed"
gh secret set SPARKLE_PRIVATE_KEY --repo rmarinsky/StudioRecorder < "$studio_key_dir/sparkle-seed"
rm "$studio_key_dir/sparkle-seed"
rmdir "$studio_key_dir"
```

This changes production signing configuration. Run it only as the repository owner when ready to configure releases. The preparation work does not create or upload production keys.

## Release procedure

1. Use a reviewed commit with green CI. Add `Docs/releases/X.Y.Z.md` before tagging. Versions are stable `X.Y.Z` only; no beta channel is implemented.
2. Run the Release workflow manually for the next version. It produces internal signed artifacts and symbols without creating a GitHub release. `CFBundleVersion` uses the Release workflow's increasing run number.
3. Verify a real install and upgrade as described below. Missing Apple credentials prevent this check; local fixture tests do not replace it.
4. After explicit approval to publish, create and push `vX.Y.Z` at the reviewed commit. Tag pushes publish a release and update the public feed.
5. Verify the release has all three assets, its tag/commit, signatures, notarization, release notes, and the production feed response. Retain debug symbols from the workflow artifacts.

The workflow imports a temporary Developer ID keychain, archives, signs the bundled `whisper-cli`, and exports using Xcode's Developer ID distribution path. Export re-signs Sparkle's nested helpers. It verifies their identities, notarizes, staples, assesses Gatekeeper, then creates and verifies the final update artifacts. A draft release receives all assets before becoming public. Published versions are never overwritten. A failed draft requires owner review before cleanup/retry.

The preflight rejects missing credentials, mismatched Sparkle keys, an existing tag release, a non-increasing marketing version, or a non-increasing build. It downloads and verifies the previous stable feed before comparing versions. A failed verification stops the release rather than changing signing identity implicitly.

GitHub Releases is the feed host; no separate update server is required. Keep the repository public and stable releases marked Latest. Manual validation artifacts have production feed settings and are for internal verification, not public distribution.

## Real upgrade rehearsal before first publication

Use two Developer ID signed, notarized builds with increasing build numbers and a separate HTTPS feed on an isolated test Mac/account. Keep the production bundle identifier and signing identity. Do not modify a signed app's Info.plist. Point only that test installation to the alternate **signed** feed using Sparkle's documented testing preference:

```sh
defaults write ua.com.rmarinsky.studiorecorder SUFeedURL -string 'https://YOUR-TEST-HOST/appcast.xml'
```

Generate the test feed with the pinned `generate_appcast` tool and the same key, with its download prefix pointing to the staged archives. After the rehearsal, quit the test app and remove only this override:

```sh
defaults delete ua.com.rmarinsky.studiorecorder SUFeedURL
```

Verify the next launch uses the production feed. Do not run this preference change on users' installations.

Exercise these cases:

- Check for Updates displays the correct version and notes; download, install, and relaunch succeed from Applications.
- An altered archive/feed or wrong signing key is rejected.
- Installation waits during recording, paused recording, Stop/closure, streaming, export, transcription, and a resumed installation. Work completes without source loss; the upgraded app opens existing projects.
- Cancel, no-network, unavailable feed, and insufficient privileges fail without replacing the current app.
- Screen Recording, Camera, Microphone permissions and Keychain access remain usable after upgrade.

Publish only after this rehearsal. The current repository has no public release or production signing credentials configured as of 2026-09-29; the signed/notarized upgrade has **not** been verified.

## Local checks

```sh
xcodegen generate
xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/releases \
  test CODE_SIGNING_ALLOWED=NO
./scripts/prepare-sparkle-release.test.sh "$PWD/build/releases/SourcePackages/artifacts/sparkle/Sparkle/bin"
actionlint .github/workflows/ci.yml .github/workflows/release.yml
shellcheck scripts/prepare-sparkle-release.sh scripts/prepare-sparkle-release.test.sh
```

The release-tool check creates a disposable key and a small ad-hoc signed fixture app in temporary storage. It uses Sparkle's real tools, verifies matching archive metadata/signatures, rejects tampering, and checks missing/mismatched credentials and version ordering. It does not use production keys or prove Developer ID installation.

## Current limits and key recovery

Only one latest arm64/macOS 26 update and full ZIP downloads are supported. Keep older compatible entries when increasing the minimum macOS version; add channels or deltas only when distribution needs them.

Because `SUVerifyUpdateBeforeExtraction` and signed feeds are enabled, Ed25519 key rotation requires a Developer ID signed **DMG** migration. Do not rotate the Apple and Sparkle signing identities together. Losing the seed cannot be repaired by replacing the GitHub variable alone. Preserve the original seed until a tested migration reaches existing installations.

References: [Sparkle setup and distribution](https://sparkle-project.org/documentation/), [publishing updates](https://sparkle-project.org/documentation/publishing/), [nested code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).
