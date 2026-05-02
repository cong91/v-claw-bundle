# PRD: Remove duplicate @openclaw/zalo root packaging

## Bead Metadata

- **Bead ID:** br-28l
- **Type:** task
- **Title:** Remove duplicate @openclaw/zalo root packaging
- **Status:** open

**Dependencies:** none known
**Parallel execution:** false
**Conflicts with:** bundle manifest/build artifact publishing work

## Problem Statement

V-Claw core bundle currently packages Zalo twice: OpenClaw already ships the bundled Zalo extension under `node_modules/openclaw/dist/extensions/zalo`, while `v-claw-bundle` also installs `@openclaw/zalo` into root `node_modules/@openclaw/zalo`. This creates duplicate payload, possible version skew, and confusion about which Zalo implementation is authoritative.

WHEN the core bundle is built for current OpenClaw releases that already contain the Zalo extension, THEN the bundle should not separately install `@openclaw/zalo` at the root.

WHEN a user later needs Zalo channel setup, THEN `v-claw-app` should use the existing OpenClaw bundled extension when present, and only run app-side/plugin install fallback if the runtime does not provide Zalo as a bundled extension.

## Scope

### In Scope

- Remove `@openclaw/zalo` from the root dependency list in the core bundle manifest.
- Remove `node_modules/@openclaw/zalo/package.json` from required bundle path validation.
- Ensure bundle verification still confirms OpenClaw's bundled Zalo extension exists under `node_modules/openclaw/dist/extensions/zalo`.
- Preserve existing full OpenClaw runtime packaging, browser runtime deps sidecar, and official-installer-equivalent npm install flow.
- Confirm `v-claw-app` bundled plugin detection and install-skip behavior covers Zalo extension paths.
- Document app-side fallback expectation: install Zalo only when needed and only if not bundled.

### Out of Scope

- Do not patch OpenClaw runtime/dist files.
- Do not force `tools.profile: "minimal"` or narrow full tool availability.
- Do not publish a release or overwrite `v1.0.3` without explicit user approval.
- Do not implement a Zalo UI/config flow beyond preserving existing app-side install fallback behavior.
- Do not remove OpenClaw's bundled `dist/extensions/zalo` or `dist/extensions/zalouser`.

## Proposed Solution

Use OpenClaw's bundled Zalo extension as the single source of truth for modern V-Claw bundles. The core bundle should install only the OpenClaw runtime package and other truly required root dependencies. Since the OpenClaw runtime already contains `dist/extensions/zalo`, `@openclaw/zalo` should not be installed again into the bundle root.

The build manifest should stop listing `@openclaw/zalo` as a pinned dependency and should stop requiring `node_modules/@openclaw/zalo/package.json`. Verification should instead check that `node_modules/openclaw/dist/extensions/zalo/package.json` exists in the staged bundle and archive.

The app side should continue using bundled-plugin detection before invoking plugin install. If Zalo is not present in a future/legacy/custom runtime, app-side install fallback may install it on demand following OpenClaw docs.

## Success Criteria

1. `@openclaw/zalo` is no longer installed into `dist-full/v-claw-core-bundle/node_modules/@openclaw/zalo` by the core bundle build.
   - Verify: `Test-Path dist-full/v-claw-core-bundle/node_modules/@openclaw/zalo/package.json` returns false after a clean build.

2. OpenClaw bundled Zalo extension remains present in the bundle.
   - Verify: `Test-Path dist-full/v-claw-core-bundle/node_modules/openclaw/dist/extensions/zalo/package.json` returns true after a clean build.

3. Bundle manifest required paths validate the bundled Zalo extension, not root `@openclaw/zalo`.
   - Verify: inspect `scripts/bundle-manifest.json` and generated `dist-full/v-claw-core-manifest.json` after build.

4. The canonical zip contains OpenClaw bundled Zalo extension and does not contain root `node_modules/@openclaw/zalo/package.json`.
   - Verify: `7z l -slt dist-full/v-claw-core-bundle-<version>-win-x64.zip` contains `node_modules\openclaw\dist\extensions\zalo\package.json` and does not contain `node_modules\@openclaw\zalo\package.json`.

5. Existing app-side bundled plugin detection still recognizes bundled extension candidates.
   - Verify: focused app tests covering `resolveBundledPluginPath` / plugin install skip behavior pass, or add focused tests if coverage is missing.

6. No OpenClaw runtime/dist monkey patching is introduced.
   - Verify: grep bundle scripts for `patch-openclaw`, `verify-openclaw`, or direct edits to `node_modules/openclaw/dist` returns no matches.

## Technical Context

- `v-claw-bundle/scripts/bundle-manifest.json` currently lists dependencies and required paths for the core bundle.
- `v-claw-bundle/scripts/build-core-bundles-win.ps1` and `v-claw-bundle/scripts/build-core-bundles.sh` install manifest dependencies with official-installer-equivalent npm global flow.
- Built OpenClaw runtime already includes Zalo under `node_modules/openclaw/dist/extensions/zalo/package.json` and Zalouser under `node_modules/openclaw/dist/extensions/zalouser/package.json`.
- `v-claw-app/src/main/services/core-bundle/index.js` has bundled plugin path candidates covering `openclaw/extensions/*` and `openclaw/dist/extensions/*`.
- `v-claw-app/src/main/services/core-bundle/core-bundle-runtime-context.js` skips plugin install if a plugin is already available as bundled.
- `v-claw-app/src/main/services/channel-config.js` has channel config flow that can trigger optional plugin install for `zalo` when needed.
- `v-claw-app/resources/plugin-install-manifest.json` currently does not list `zalo` as a managed optional plugin.

## Affected Files

- `scripts/bundle-manifest.json`
- `scripts/build-core-bundles-win.ps1`
- `scripts/build-core-bundles.sh`
- `dist-full/v-claw-core-bundle/package.json` (generated verification target)
- `dist-full/v-claw-core-bundle/node_modules/openclaw/dist/extensions/zalo/package.json` (generated verification target)
- `dist-full/v-claw-core-bundle/node_modules/@openclaw/zalo/package.json` (should be absent after rebuild)
- `src/main/services/core-bundle/index.js` in `v-claw-app` (read/verify only unless tests show gap)
- `src/main/services/core-bundle/core-bundle-runtime-context.js` in `v-claw-app` (read/verify only unless tests show gap)
- `src/main/services/channel-config.js` in `v-claw-app` (read/verify only unless tests show gap)

## Tasks

### Remove root Zalo package from bundle manifest [bundle]

The core bundle manifest no longer declares `@openclaw/zalo` as a root dependency or required root package path.

**Metadata:**

```yaml
depends_on: []
parallel: false
conflicts_with:
  - scripts/bundle-manifest.json
files:
  - scripts/bundle-manifest.json
```

**Verification:**

- `Select-String -Path scripts/bundle-manifest.json -Pattern '@openclaw/zalo'` returns no matches.
- `node -e "const m=require('./scripts/bundle-manifest.json'); if (m.dependencies['@openclaw/zalo']) process.exit(1); if ((m.requiredPaths||[]).some(p=>p.includes('@openclaw/zalo'))) process.exit(1);"`

### Verify bundled Zalo extension as authoritative source [bundle]

The clean rebuilt bundle contains OpenClaw's bundled Zalo extension and excludes the duplicate root `@openclaw/zalo` package.

**Metadata:**

```yaml
depends_on:
  - Remove root Zalo package from bundle manifest
parallel: false
conflicts_with:
  - dist-full
files:
  - scripts/build-core-bundles-win.ps1
  - scripts/build-core-bundles.sh
  - scripts/bundle-manifest.json
```

**Verification:**

- `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/build-core-bundles-win.ps1 -Clean -OutputDir ./dist-full-zalo-clean`
- `Test-Path ./dist-full-zalo-clean/v-claw-core-bundle/node_modules/openclaw/dist/extensions/zalo/package.json` returns true.
- `Test-Path ./dist-full-zalo-clean/v-claw-core-bundle/node_modules/@openclaw/zalo/package.json` returns false.

### Verify app-side bundled plugin skip/fallback behavior [app]

V-Claw app continues to skip plugin install when Zalo is bundled, while retaining install fallback for runtimes that do not ship Zalo.

**Metadata:**

```yaml
depends_on: []
parallel: true
conflicts_with: []
files:
  - ../v-claw-app/src/main/services/core-bundle/index.js
  - ../v-claw-app/src/main/services/core-bundle/core-bundle-runtime-context.js
  - ../v-claw-app/src/main/services/channel-config.js
  - ../v-claw-app/test/core-bundle.test.js
```

**Verification:**

- `node --test test/core-bundle.test.js` in `../v-claw-app` passes after any needed test additions.
- If no existing test proves Zalo bundled skip behavior, add a focused test that `dist/extensions/zalo` is detected before invoking install.

### Verify final archive and manifest [release]

The generated zip and manifest reflect a single Zalo source: OpenClaw bundled extension only.

**Metadata:**

```yaml
depends_on:
  - Verify bundled Zalo extension as authoritative source
parallel: false
conflicts_with:
  - dist-full-zalo-clean
files:
  - dist-full-zalo-clean/v-claw-core-manifest.json
  - dist-full-zalo-clean/v-claw-core-bundle-*.zip
```

**Verification:**

- `7z l -slt ./dist-full-zalo-clean/v-claw-core-bundle-*.zip` contains `node_modules\openclaw\dist\extensions\zalo\package.json`.
- `7z l -slt ./dist-full-zalo-clean/v-claw-core-bundle-*.zip` does not contain `node_modules\@openclaw\zalo\package.json`.
- `git diff --check -- scripts/bundle-manifest.json scripts/build-core-bundles-win.ps1 scripts/build-core-bundles.sh` reports no whitespace errors other than existing LF/CRLF warnings.

## Risks

- OpenClaw may still have an undocumented resolver path that expects root `node_modules/@openclaw/zalo` for older/custom installs. Mitigation: verify current runtime resolves `dist/extensions/zalo` and app install skip behavior before publishing.
- Removing `@openclaw/zalo` changes artifact contents and SHA; publishing must be explicit and version/release strategy must be confirmed by the user.
- If future OpenClaw releases stop bundling Zalo, V-Claw must rely on app-side on-demand install fallback or reintroduce a compatibility bundle profile.

## Open Questions

- Should the rebuilt artifact remain `v1.0.3`, or should the bundle version be bumped before publishing?
- Should `zalo` be added to `v-claw-app/resources/plugin-install-manifest.json` as an optional on-demand plugin, or should channel-config continue owning Zalo installation triggers?
- Do we want an explicit build-time assertion that `node_modules/openclaw/dist/extensions/zalo/package.json` exists whenever root `@openclaw/zalo` is absent?

