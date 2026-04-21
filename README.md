# v-claw-bundle

`v-claw-bundle` is the canonical producer repo for V-Claw core bundle artifacts, runtime payload packaging, checksums, and release manifests.

`v-claw-app` is only the Electron shell/application consumer. It must not build or publish bundle/runtime payloads.

## Ownership boundary

Producer-side ownership in this repo:

- pinned runtime dependency set
- bundle staging and materialization
- bundle archive naming
- checksum generation
- release manifest generation
- release upload contract metadata

Consumer-side ownership in `../v-claw-app/`:

- Electron shell build
- UI orchestration
- install/bootstrap consumption of published bundle contract

## Canonical Windows producer flow

Bundle contract source of truth lives in `scripts/bundle-manifest.json`.

Run either [`npm run build:core:win`](package.json) or [`build-core-bundles-win.bat`](build-core-bundles-win.bat).

Direct PowerShell entrypoint:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-core-bundles-win.ps1 -Clean
```

## Expected output

Artifacts are emitted under `dist/`:

- `v-claw-core-bundle/` - staging directory used to materialize the pinned runtime payload
- `v-claw-core-bundle-<version>-win-x64.zip` - canonical Windows core bundle artifact
- `v-claw-core-bundle-<version>-win-x64.zip.sha256` - checksum companion file
- `v-claw-core-manifest.json` - machine-readable release manifest consumed by the shell

## Release contract

The generated manifest declares:

- `bundleVersion`
- `releaseTag`
- `bundleRepo`
- `artifactNaming.core`
- `releaseAssetUrlPattern`
- `artifacts.win-x64.core`

That manifest is the producer-side contract to upload alongside the bundle asset in GitHub Releases.
