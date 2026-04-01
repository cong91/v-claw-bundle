param(
  [Parameter(Mandatory=$true)]
  [string]$Version,

  [Parameter(Mandatory=$true)]
  [string]$Source
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) {
  Write-Host $msg -ForegroundColor Red
  exit 1
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DistDir = Join-Path $RepoRoot ("dist/" + $Version)
$ManifestPath = Join-Path $DistDir "v-claw-core-manifest.json"
$BundleRepoUrl = "https://github.com/cong91/v-claw-bundle"
$ReleaseTag = "v$Version"
$SourceRoot = (Resolve-Path $Source).Path

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$CoreNodeModulesSrc = Join-Path $SourceRoot "node_modules"
$CorePackageJsonSrc = Join-Path $SourceRoot "package.json"
$CorePackageLockSrc = Join-Path $SourceRoot "package-lock.json"
if (-not (Test-Path $CoreNodeModulesSrc)) {
  Fail "Missing required source path: $CoreNodeModulesSrc"
}
if (-not (Test-Path $CorePackageJsonSrc)) {
  Fail "Missing required source path: $CorePackageJsonSrc"
}

function Test-DirHasFiles($dir) {
  return (Test-Path $dir) -and (Get-ChildItem -Force $dir | Select-Object -First 1)
}

function New-ZipFromDir($srcDir, $outZip) {
  if (Test-Path $outZip) { Remove-Item -Force $outZip }
  Compress-Archive -Path (Join-Path $srcDir '*') -DestinationPath $outZip -Force
}

function Get-Sha256($file) {
  return ((Get-FileHash -Path $file -Algorithm SHA256).Hash).ToLower()
}

function Build-Zip($platformKey, $coreNodeModulesSrc, $runtimeSrc) {
  $coreZip = Join-Path $DistDir ("v-claw-core-bundle-$Version-$platformKey.zip")
  $runtimeZip = Join-Path $DistDir ("v-claw-runtime-bundle-$Version-$platformKey.zip")

  $stageRoot = Join-Path $env:TEMP ("vclaw-bundle-" + [guid]::NewGuid().ToString())
  $coreStage = Join-Path $stageRoot 'core'
  $runtimeStage = Join-Path $stageRoot 'runtime'
  New-Item -ItemType Directory -Force -Path $coreStage | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeStage | Out-Null

  Copy-Item -Force $CorePackageJsonSrc (Join-Path $coreStage 'package.json')
  if (Test-Path $CorePackageLockSrc) {
    Copy-Item -Force $CorePackageLockSrc (Join-Path $coreStage 'package-lock.json')
  }
  Copy-Item -Recurse -Force $coreNodeModulesSrc (Join-Path $coreStage 'node_modules')
  New-ZipFromDir $coreStage $coreZip

  Copy-Item -Recurse -Force $runtimeSrc (Join-Path $runtimeStage 'runtime')
  New-ZipFromDir $runtimeStage $runtimeZip

  $result = [ordered]@{
    platform = $platformKey
    core = [ordered]@{
      file = [System.IO.Path]::GetFileName($coreZip)
      sha256 = Get-Sha256 $coreZip
      sizeBytes = (Get-Item $coreZip).Length
      url = "$BundleRepoUrl/releases/download/$ReleaseTag/$([System.IO.Path]::GetFileName($coreZip))"
    }
    runtime = [ordered]@{
      file = [System.IO.Path]::GetFileName($runtimeZip)
      sha256 = Get-Sha256 $runtimeZip
      sizeBytes = (Get-Item $runtimeZip).Length
      url = "$BundleRepoUrl/releases/download/$ReleaseTag/$([System.IO.Path]::GetFileName($runtimeZip))"
    }
  }

  Remove-Item -Recurse -Force $stageRoot
  return $result
}

$artifacts = [ordered]@{}

$winRuntime = Join-Path $SourceRoot 'resources/runtime/node-win32-x64'
if (-not (Test-DirHasFiles $winRuntime)) {
  $winRuntime = Join-Path $SourceRoot 'resources/runtime/node-win-x64'
}
if (Test-DirHasFiles $winRuntime) {
  $built = Build-Zip 'win-x64' $CoreNodeModulesSrc $winRuntime
  $artifacts[$built.platform] = [ordered]@{ core = $built.core; runtime = $built.runtime }
}

$darwinX64 = Join-Path $SourceRoot 'resources/runtime/node-darwin-x64'
if (Test-DirHasFiles $darwinX64) {
  $built = Build-Zip 'darwin-x64' $CoreNodeModulesSrc $darwinX64
  $artifacts[$built.platform] = [ordered]@{ core = $built.core; runtime = $built.runtime }
}

$darwinArm64 = Join-Path $SourceRoot 'resources/runtime/node-darwin-arm64'
if (Test-DirHasFiles $darwinArm64) {
  $built = Build-Zip 'darwin-arm64' $CoreNodeModulesSrc $darwinArm64
  $artifacts[$built.platform] = [ordered]@{ core = $built.core; runtime = $built.runtime }
}

$linuxX64 = Join-Path $SourceRoot 'resources/runtime/node-linux-x64'
if (Test-DirHasFiles $linuxX64) {
  $built = Build-Zip 'linux-x64' $CoreNodeModulesSrc $linuxX64
  $artifacts[$built.platform] = [ordered]@{ core = $built.core; runtime = $built.runtime }
}

if ($artifacts.Count -eq 0) {
  Fail "No runtime payloads found under $SourceRoot/resources/runtime"
}

$manifest = [ordered]@{
  bundleVersion = $Version
  publishedAt = $null
  artifacts = $artifacts
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $ManifestPath -Encoding utf8

Write-Ok "Built core bundles under $DistDir"
Write-Host "Manifest: $ManifestPath"
Get-ChildItem $DistDir | Select-Object Name,Length | Format-Table -AutoSize
