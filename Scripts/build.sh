#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$repo/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/aire-disco-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$repo/Sources/"*.swift "$stage/"
cp "$repo/Scripts/Icon.swift" "$stage/"

app="$stage/Aire Disco.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X "$repo/Sources/Info.plist" "$app/Contents/Info.plist"
cache="${AIRE_MODULE_CACHE:-$stage/modules}"
xcrun swiftc -module-cache-path "$cache" "$stage/Icon.swift" -o "$stage/draw-icon"
"$stage/draw-icon" "$app/Contents/Resources"

for arch in arm64 x86_64; do
    xcrun swiftc -target "$arch-apple-macos14.0" -module-cache-path "$cache" \
        "$stage/Engine.swift" "$stage/Aire.swift" -o "$stage/AireDisco-$arch"
done
xcrun lipo -create "$stage/AireDisco-arm64" "$stage/AireDisco-x86_64" -output "$app/Contents/MacOS/AireDisco"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
archive="Aire-Disco-${version}-macOS.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$output/$archive"
(
    cd "$output"
    shasum -a 256 "$archive" > SHA256SUMS.txt
)
printf 'Descarga: %s\n' "$output/$archive"
