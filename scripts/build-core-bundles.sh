#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [uclaw-vclaw-app-path]" >&2
  exit 1
fi

VERSION="$1"
SRC_ROOT="${2:-/Users/mrcagents/Work/projects/u-claw/v-claw-app}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist/$VERSION"
MANIFEST_PATH="$DIST_DIR/v-claw-core-manifest.json"
BUNDLE_REPO_URL="https://github.com/cong91/v-claw-bundle"
RELEASE_TAG="v$VERSION"

mkdir -p "$DIST_DIR"

require_path() {
  local p="$1"
  if [ ! -e "$p" ]; then
    echo "Missing required source path: $p" >&2
    exit 1
  fi
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    sha256sum "$1" | awk '{print tolower($1)}'
  fi
}

build_zip() {
  local platform_key="$1"
  local core_src="$2"
  local runtime_src="$3"
  local core_zip="$DIST_DIR/v-claw-core-bundle-${VERSION}-${platform_key}.zip"
  local runtime_zip="$DIST_DIR/v-claw-runtime-bundle-${VERSION}-${platform_key}.zip"
  local stage_root
  stage_root="$(mktemp -d)"
  mkdir -p "$stage_root/core" "$stage_root/runtime"
  cp -R "$core_src" "$stage_root/core/openclaw"
  (cd "$stage_root/core" && zip -qr "$core_zip" .)
  rm -rf "$stage_root/runtime" && mkdir -p "$stage_root/runtime"
  cp -R "$runtime_src" "$stage_root/runtime/runtime"
  (cd "$stage_root/runtime" && zip -qr "$runtime_zip" .)
  rm -rf "$stage_root"
  local core_sha runtime_sha core_size runtime_size
  core_sha="$(sha256_of "$core_zip")"
  runtime_sha="$(sha256_of "$runtime_zip")"
  core_size="$(stat -f%z "$core_zip" 2>/dev/null || stat -c%s "$core_zip")"
  runtime_size="$(stat -f%z "$runtime_zip" 2>/dev/null || stat -c%s "$runtime_zip")"
  printf '%s|%s|%s|%s|%s|%s\n' "$platform_key" "$core_zip" "$core_sha" "$core_size" "$runtime_zip" "$runtime_sha|$runtime_size"
}

OPENCLAW_SRC="$SRC_ROOT/node_modules/openclaw"
require_path "$OPENCLAW_SRC"

runtime_has_files() {
  local dir="$1"
  [ -d "$dir" ] && [ -n "$(find "$dir" -mindepth 1 -print -quit 2>/dev/null)" ]
}

RESULTS=()

if runtime_has_files "$SRC_ROOT/resources/runtime/node-darwin-x64"; then
  RESULTS+=("$(build_zip darwin-x64 "$OPENCLAW_SRC" "$SRC_ROOT/resources/runtime/node-darwin-x64")")
fi

if runtime_has_files "$SRC_ROOT/resources/runtime/node-darwin-arm64"; then
  RESULTS+=("$(build_zip darwin-arm64 "$OPENCLAW_SRC" "$SRC_ROOT/resources/runtime/node-darwin-arm64")")
fi

if runtime_has_files "$SRC_ROOT/resources/runtime/node-win32-x64"; then
  RESULTS+=("$(build_zip win-x64 "$OPENCLAW_SRC" "$SRC_ROOT/resources/runtime/node-win32-x64")")
elif runtime_has_files "$SRC_ROOT/resources/runtime/node-win-x64"; then
  RESULTS+=("$(build_zip win-x64 "$OPENCLAW_SRC" "$SRC_ROOT/resources/runtime/node-win-x64")")
fi

if runtime_has_files "$SRC_ROOT/resources/runtime/node-linux-x64"; then
  RESULTS+=("$(build_zip linux-x64 "$OPENCLAW_SRC" "$SRC_ROOT/resources/runtime/node-linux-x64")")
fi

if [ ${#RESULTS[@]} -eq 0 ]; then
  echo "No runtime payloads found under $SRC_ROOT/resources/runtime" >&2
  exit 1
fi

python3 - <<'PY' "$MANIFEST_PATH" "$VERSION" "$BUNDLE_REPO_URL" "$RELEASE_TAG" "${RESULTS[@]}"
import json, os, sys
manifest_path, version, repo_url, release_tag, *results = sys.argv[1:]
artifacts = {}
for row in results:
    platform_key, core_zip, core_sha, core_size, runtime_zip, tail = row.split('|', 5)
    runtime_sha, runtime_size = tail.split('|', 1)
    core_file = os.path.basename(core_zip)
    runtime_file = os.path.basename(runtime_zip)
    artifacts[platform_key] = {
        "core": {
            "file": core_file,
            "sha256": core_sha,
            "sizeBytes": int(core_size),
            "url": f"{repo_url}/releases/download/{release_tag}/{core_file}",
        },
        "runtime": {
            "file": runtime_file,
            "sha256": runtime_sha,
            "sizeBytes": int(runtime_size),
            "url": f"{repo_url}/releases/download/{release_tag}/{runtime_file}",
        },
    }
manifest = {
    "bundleVersion": version,
    "publishedAt": None,
    "artifacts": artifacts,
}
with open(manifest_path, 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2)
print(manifest_path)
PY

echo "Built core bundles under $DIST_DIR"
echo "Manifest: $MANIFEST_PATH"
