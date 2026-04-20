# v-claw-bundle

Core bundle artifacts for V-Claw thin-shell desktop delivery.

This repo is the canonical source for building and publishing versioned core bundle artifacts consumed by `u-claw/v-claw-app`.

## Windows local build

Source of truth for pinned bundle contents lives in `scripts/bundle-manifest.json`.

Canonical local build command:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-core-bundles-win.ps1 -Clean
```

Expected output under `dist/`:

- `v-claw-bundle/` - extracted staging snapshot
- `v-claw-bundle.zip` - canonical release upload asset
- `v-claw-bundle.zip.sha256` - companion checksum
- `v-claw-core-manifest.json` - minimal machine-readable manifest
