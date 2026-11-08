#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/aire-disco-check.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$repo/Sources/Engine.swift" "$repo/Tests/EngineCheck.swift" "$stage/"
xcrun swiftc -module-cache-path "${AIRE_MODULE_CACHE:-$stage/modules}" "$stage/Engine.swift" "$stage/EngineCheck.swift" -o "$stage/check"
"$stage/check"
