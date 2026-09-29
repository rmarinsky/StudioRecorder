#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# != 7 ]]; then
    echo 'Usage: prepare-sparkle-release.sh APP OUTPUT VERSION BUILD NOTES PRIVATE_KEY SPARKLE_TOOLS_DIR' >&2
    exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
output="$2"
version="$3"
build="$4"
notes="$5"
key="$6"
tools="$7"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Invalid release version or build number.' >&2; exit 1;
}
test -d "$app"
test -s "$notes"
test -s "$key"
test -x "$tools/generate_appcast"
test -x "$tools/sign_update"
if [[ -e "$output" ]]; then
    echo 'Release output must not already exist.' >&2
    exit 1
fi
mkdir -p "$(dirname "$output")"
staging="$(mktemp -d "$(dirname "$output")/.sparkle-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
asset="Studio-Recorder-$version-macOS-arm64.zip"
ditto -c -k --keepParent "$app" "$staging/$asset"
cp "$notes" "$staging/${asset%.zip}.md"
"$tools/generate_appcast" \
    --ed-key-file "$key" \
    --download-url-prefix "https://github.com/rmarinsky/StudioRecorder/releases/download/v$version/" \
    --link 'https://rmarinsky.com.ua/en/studio-recorder/' \
    --embed-release-notes --maximum-deltas 0 --maximum-versions 1 --versions "$build" \
    -o "$staging/appcast.xml" "$staging"
swift "$root/scripts/validate-sparkle-release.swift" "$app" "$staging/$asset" "$staging/appcast.xml" "$version" "$build"
"$tools/sign_update" --verify --ed-key-file "$key" "$staging/appcast.xml"
rm "$staging/${asset%.zip}.md"
(cd "$staging" && shasum -a 256 "$asset" > "$asset.sha256")
mv "$staging" "$output"
echo "Prepared signed update artifacts: $output"
