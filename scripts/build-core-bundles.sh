#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_PATH="${1:-$SCRIPT_DIR/bundle-manifest.json}"
OUTPUT_DIR="${2:-$REPO_ROOT/dist}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    echo python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo python
    return 0
  fi
  return 1
}

require_command npm
PYTHON_BIN="$(python_bin || true)"
if [ -z "$PYTHON_BIN" ]; then
  echo "python/python3 is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

"$PYTHON_BIN" - <<'PY' "$MANIFEST_PATH" "$OUTPUT_DIR"
import json
import os
import shutil
import subprocess
import sys
import zipfile
from hashlib import sha256
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
output_dir = Path(sys.argv[2]).resolve()
if not manifest_path.exists():
    raise SystemExit(f"Missing manifest file: {manifest_path}")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
bundle_name = str(manifest.get("bundleName") or "").strip()
bundle_version = str(manifest.get("bundleVersion") or "").strip()
platform = str(manifest.get("platform") or "").strip()
bundle_repo = str(manifest.get("bundleRepo") or "").strip()
manifest_name = str(manifest.get("manifestName") or "").strip()
release_tag = str(manifest.get("releaseTag") or f"v{bundle_version}").strip()
release_asset_url_pattern = str(manifest.get("releaseAssetUrlPattern") or "").strip()
core_template = str(((manifest.get("artifactNaming") or {}).get("core") or "")).strip()
dependencies = dict(manifest.get("dependencies") or {})
required_paths = list(manifest.get("requiredPaths") or [])
forbidden_dependencies = list(manifest.get("forbiddenDependencies") or [])
stage_package = dict(manifest.get("stagePackage") or {})
stage_package_name = str(stage_package.get("name") or bundle_name).strip()
stage_package_description = str(stage_package.get("description") or "Canonical V-Claw core bundle payload").strip()
stage_package_private = bool(stage_package.get("private", True))

for label, value in {
    "bundleName": bundle_name,
    "bundleVersion": bundle_version,
    "platform": platform,
    "bundleRepo": bundle_repo,
    "manifestName": manifest_name,
    "releaseAssetUrlPattern": release_asset_url_pattern,
    "artifactNaming.core": core_template,
}.items():
    if not value:
        raise SystemExit(f"Manifest {label} is required")
if not dependencies:
    raise SystemExit("Manifest dependencies must not be empty")
if not required_paths:
    raise SystemExit("Manifest requiredPaths must not be empty")

core_asset_name = core_template.replace("{version}", bundle_version).replace("{platform}", platform)
checksum_name = f"{core_asset_name}.sha256"
stage_dir = output_dir / bundle_name
asset_path = output_dir / core_asset_name
checksum_path = output_dir / checksum_name
core_manifest_path = output_dir / manifest_name

if stage_dir.exists():
    shutil.rmtree(stage_dir)
for path in (asset_path, checksum_path, core_manifest_path):
    if path.exists():
        path.unlink()

stage_dir.mkdir(parents=True, exist_ok=True)
stage_package_json = {
    "name": stage_package_name,
    "version": bundle_version,
    "private": stage_package_private,
    "description": stage_package_description,
    "dependencies": dependencies,
}
(stage_dir / "package.json").write_text(json.dumps(stage_package_json, indent=2) + "\n", encoding="utf-8")

subprocess.run(
    ["npm", "install", "--prefix", str(stage_dir), "--omit=dev", "--ignore-scripts", "--no-fund", "--no-audit"],
    check=True,
)

for relative_path in required_paths:
    if not (stage_dir / relative_path).exists():
        raise SystemExit(f"Missing required bundle path: {relative_path}")

for dependency_name in forbidden_dependencies:
    if dependency_name and (stage_dir / "node_modules" / dependency_name).exists():
        raise SystemExit(f"Forbidden dependency detected in bundle: {dependency_name}")

with zipfile.ZipFile(asset_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for item in sorted(stage_dir.rglob("*")):
        if item.is_file():
            archive.write(item, item.relative_to(stage_dir))

hash_value = sha256(asset_path.read_bytes()).hexdigest()
checksum_path.write_text(f"{hash_value} *{core_asset_name}\n", encoding="utf-8")
asset_size_bytes = asset_path.stat().st_size
asset_url = release_asset_url_pattern.replace("{tag}", release_tag).replace("{file}", core_asset_name)
core_manifest = {
    "manifestVersion": 1,
    "bundleName": bundle_name,
    "bundleVersion": bundle_version,
    "releaseTag": release_tag,
    "bundleRepo": bundle_repo,
    "generatedAt": __import__("datetime").datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "releaseAssetUrlPattern": release_asset_url_pattern,
    "artifactNaming": {
        "core": core_template,
    },
    "artifacts": {
        platform: {
            "core": {
                "file": core_asset_name,
                "sha256": hash_value,
                "sizeBytes": asset_size_bytes,
                "url": asset_url,
            }
        }
    },
}
core_manifest_path.write_text(json.dumps(core_manifest, indent=2) + "\n", encoding="utf-8")
print(asset_path)
print(checksum_path)
print(core_manifest_path)
PY

echo "Built canonical core bundle artifacts under $OUTPUT_DIR"
