param(
    [string]$ManifestPath,
    [string]$OutputDir,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Get-NormalizedRelativePath {
    param([string]$RelativePath)

    return ($RelativePath -replace '/', '\\')
}

function Get-StagePath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $normalizedRelativePath = Get-NormalizedRelativePath -RelativePath $RelativePath
    return (Join-Path $Root $normalizedRelativePath)
}

function New-CleanDirectory {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-JsonObject {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Fail "Missing manifest file: $Path"
    }

    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function ConvertTo-OrderedMap {
    param($InputObject)

    $map = [ordered]@{}

    if ($InputObject) {
        foreach ($property in $InputObject.PSObject.Properties) {
            $map[$property.Name] = [string]$property.Value
        }
    }

    return $map
}

function Assert-CommandExists {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Missing required command: $Name"
    }
}

function Assert-PathExists {
    param(
        [string]$Root,
        [string[]]$RelativePaths
    )

    $missing = @()

    foreach ($relativePath in $RelativePaths) {
        $candidate = Get-StagePath -Root $Root -RelativePath $relativePath
        if (-not (Test-Path $candidate)) {
            $missing += $relativePath
        }
    }

    if ($missing.Count -gt 0) {
        Fail ('Missing required bundle paths: ' + ($missing -join ', '))
    }
}

function Assert-ForbiddenDependenciesAbsent {
    param(
        [string]$Root,
        [string[]]$PackageNames
    )

    if (-not $PackageNames) {
        return
    }

    foreach ($packageName in $PackageNames) {
        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            continue
        }

        $packagePath = Get-StagePath -Root $Root -RelativePath (Join-Path 'node_modules' ([string]$packageName))
        if (Test-Path $packagePath) {
            Fail "Forbidden dependency detected in bundle: $packageName"
        }
    }
}

function New-ChecksumFile {
    param(
        [string]$AssetPath,
        [string]$ChecksumPath
    )

    $hash = (Get-FileHash -Path $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetFileName = Split-Path $AssetPath -Leaf
    $checksumLine = "{0} *{1}" -f $hash, $assetFileName
    $checksumLine | Out-File -FilePath $ChecksumPath -Encoding utf8
    return $hash
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$resolvedManifestPath = if ($ManifestPath) { $ManifestPath } else { Join-Path $scriptDir 'bundle-manifest.json' }
$resolvedOutputDir = if ($OutputDir) { $OutputDir } else { Join-Path $repoRoot 'dist' }

$resolvedManifestPath = (Resolve-Path $resolvedManifestPath).Path
$manifest = Get-JsonObject -Path $resolvedManifestPath

$bundleName = [string]$manifest.bundleName
$bundleVersion = [string]$manifest.bundleVersion
$assetName = [string]$manifest.assetName
$checksumName = [string]$manifest.checksumName
$coreManifestName = [string]$manifest.manifestName
$releaseTag = [string]$manifest.releaseTag
$platform = [string]$manifest.platform
$dependencies = ConvertTo-OrderedMap -InputObject $manifest.dependencies
$forbiddenDependencies = @()
if ($manifest.PSObject.Properties.Name -contains 'forbiddenDependencies' -and $null -ne $manifest.forbiddenDependencies) {
    $forbiddenDependencies = @($manifest.forbiddenDependencies)
}
$requiredPaths = @($manifest.requiredPaths)
$stagePackageName = [string]$manifest.stagePackage.name
$stagePackageDescription = [string]$manifest.stagePackage.description
$stagePackagePrivate = [bool]$manifest.stagePackage.private

if ([string]::IsNullOrWhiteSpace($bundleName)) {
    Fail 'Manifest bundleName is required'
}
if ([string]::IsNullOrWhiteSpace($bundleVersion)) {
    Fail 'Manifest bundleVersion is required'
}
if ([string]::IsNullOrWhiteSpace($assetName)) {
    Fail 'Manifest assetName is required'
}
if ([string]::IsNullOrWhiteSpace($checksumName)) {
    Fail 'Manifest checksumName is required'
}
if ([string]::IsNullOrWhiteSpace($coreManifestName)) {
    Fail 'Manifest manifestName is required'
}
if ([string]::IsNullOrWhiteSpace($platform)) {
    Fail 'Manifest platform is required'
}
if (-not $dependencies.Count) {
    Fail 'Manifest dependencies must not be empty'
}
if (-not $requiredPaths.Count) {
    Fail 'Manifest requiredPaths must not be empty'
}
if ([string]::IsNullOrWhiteSpace($stagePackageName)) {
    $stagePackageName = $bundleName
}
if ([string]::IsNullOrWhiteSpace($stagePackageDescription)) {
    $stagePackageDescription = 'Release-grade V-Claw runtime bundle'
}
if ([string]::IsNullOrWhiteSpace($releaseTag)) {
    $releaseTag = "v$bundleVersion"
}

Assert-CommandExists -Name 'npm'

$resolvedOutputDir = [System.IO.Path]::GetFullPath($resolvedOutputDir)
$stageDir = Join-Path $resolvedOutputDir $bundleName
$assetPath = Join-Path $resolvedOutputDir $assetName
$checksumPath = Join-Path $resolvedOutputDir $checksumName
$coreManifestPath = Join-Path $resolvedOutputDir $coreManifestName

if ($Clean) {
    Write-Info "Cleaning output directory: $resolvedOutputDir"
    New-CleanDirectory -Path $resolvedOutputDir
}
else {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
    if (Test-Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
}

if (Test-Path $assetPath) {
    Remove-Item -Path $assetPath -Force
}
if (Test-Path $checksumPath) {
    Remove-Item -Path $checksumPath -Force
}
if (Test-Path $coreManifestPath) {
    Remove-Item -Path $coreManifestPath -Force
}

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$stagePackageJson = [ordered]@{
    name         = $stagePackageName
    version      = $bundleVersion
    private      = $stagePackagePrivate
    description  = $stagePackageDescription
    dependencies = $dependencies
}

$stagePackageJsonPath = Join-Path $stageDir 'package.json'
$stagePackageJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $stagePackageJsonPath -Encoding utf8

Write-Info "Installing pinned dependencies into: $stageDir"
& npm install --prefix $stageDir --omit=dev --ignore-scripts --no-fund --no-audit
if ($LASTEXITCODE -ne 0) {
    Fail 'npm install failed while building v-claw-bundle'
}

Assert-ForbiddenDependenciesAbsent -Root $stageDir -PackageNames $forbiddenDependencies
Assert-PathExists -Root $stageDir -RelativePaths $requiredPaths

Write-Info "Creating canonical archive: $assetPath"
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $assetPath -Force

$sha256 = New-ChecksumFile -AssetPath $assetPath -ChecksumPath $checksumPath
$assetSizeBytes = (Get-Item $assetPath).Length

$coreManifest = [ordered]@{
    manifestVersion           = 1
    bundleName                = $bundleName
    bundleVersion             = $bundleVersion
    requiredCoreBundleVersion = $bundleVersion
    releaseTag                = $releaseTag
    platform                  = $platform
    generatedAt               = (Get-Date).ToUniversalTime().ToString('o')
    platforms                 = [ordered]@{
        $platform = [ordered]@{
            core = [ordered]@{
                file      = $assetName
                sha256    = $sha256
                sizeBytes = $assetSizeBytes
            }
        }
    }
}

$coreManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $coreManifestPath -Encoding utf8

Write-Ok "Bundle staged at: $stageDir"
Write-Ok "Bundle asset: $assetPath"
Write-Ok "Checksum: $checksumPath"
Write-Ok "Core manifest: $coreManifestPath"
