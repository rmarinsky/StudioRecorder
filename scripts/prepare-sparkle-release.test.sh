#!/usr/bin/env bash
set -euo pipefail
umask 077

root="$(cd "$(dirname "$0")/.." && pwd)"
tools="${1:?Pass the resolved Sparkle bin directory}"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
app="$fixture/Studio Recorder.app"
mkdir -p "$app/Contents/MacOS"
openssl rand -base64 32 > "$fixture/key"
printf 'int main(void) { return 0; }\n' | xcrun clang -target arm64-apple-macos26 \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -x c - -o "$app/Contents/MacOS/Fixture"
swift - "$fixture/key" "$app/Contents/Info.plist" <<'SWIFT'
import CryptoKit
import Foundation
let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines))!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let info: [String: Any] = [
    "CFBundleIdentifier": "ua.com.rmarinsky.studiorecorder", "CFBundleName": "Studio Recorder",
    "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture",
    "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "123", "LSMinimumSystemVersion": "26.0",
    "StudioRecorderUpdatesEnabled": "YES", "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
    "SUFeedURL": "https://github.com/rmarinsky/StudioRecorder/releases/latest/download/appcast.xml",
    "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUAutomaticallyUpdate": false,
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT
codesign --force --sign - "$app"
printf '# Studio Recorder 0.1.0\n\nTest release notes.\n' > "$fixture/notes.md"

"$root/scripts/prepare-sparkle-release.sh" "$app" "$fixture/release" 0.1.0 123 "$fixture/notes.md" "$fixture/key" "$tools"
archive="$fixture/release/Studio-Recorder-0.1.0-macOS-arm64.zip"
feed="$fixture/release/appcast.xml"
test -s "$archive.sha256"
"$tools/sign_update" --verify --ed-key-file "$fixture/key" "$feed"

reject() {
    local expected="$1"
    shift
    if "$@" > "$fixture/rejected.log" 2>&1; then
        echo "Expected rejection: $expected" >&2
        exit 1
    fi
    if ! grep -q "$expected" "$fixture/rejected.log"; then
        cat "$fixture/rejected.log" >&2
        echo "Failed for a different reason than: $expected" >&2
        exit 1
    fi
}

# Alter one archive byte without changing the length in the enclosure.
cp "$archive" "$fixture/original.zip"
python3 - "$archive" <<'PY'
import sys
with open(sys.argv[1], "r+b") as archive:
    archive.seek(50)
    value = archive.read(1)[0]
    archive.seek(50)
    archive.write(bytes([value ^ 1]))
PY
reject 'archive signature' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.0 123
cp "$fixture/original.zip" "$archive"

# A matching archive signature must still reject the wrong bundled public key.
cp "$app/Contents/Info.plist" "$fixture/original.plist"
/usr/libexec/PlistBuddy -c 'Set :SUPublicEDKey AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' "$app/Contents/Info.plist"
reject 'archive signature' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.0 123
cp "$fixture/original.plist" "$app/Contents/Info.plist"

reject 'version' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.1 123
reject 'build' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.0 124
/usr/libexec/PlistBuddy -c 'Set :SUFeedURL http://example.test/appcast.xml' "$app/Contents/Info.plist"
reject 'feed URL' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.0 123
cp "$fixture/original.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ua.com.rmarinsky.studiorecorder.dev' "$app/Contents/Info.plist"
reject 'bundle identifier' swift "$root/scripts/validate-sparkle-release.swift" "$app" "$archive" "$feed" 0.1.0 123
cp "$fixture/original.plist" "$app/Contents/Info.plist"

cp "$feed" "$fixture/original.xml"
python3 - "$feed" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("Test release notes", "Altered release notes"))
PY
reject 'Error' "$tools/sign_update" --verify --ed-key-file "$fixture/key" "$feed"
cp "$fixture/original.xml" "$feed"
echo 'Sparkle release preparation checks passed.'
