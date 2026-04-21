param(
    [string]$ManifestPath,
    [string]$OutputDir,
    [switch]$Clean,
    [int]$ZipTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

trap {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $_.ToString()
    }

    Write-Host "[ERROR] $message" -ForegroundColor Red
    [Environment]::Exit(1)
}

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

function Remove-FileWithRetry {
    param(
        [string]$Path,
        [int]$MaxAttempts = 5,
        [int]$DelayMilliseconds = 1000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                Fail "Cannot remove file after $MaxAttempts attempts: $Path. $($_.Exception.Message)"
            }

            Write-Info ("File remove retry {0}/{1}: {2}" -f $attempt, $MaxAttempts, $Path)
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Remove-DirectoryWithRetry {
    param(
        [string]$Path,
        [int]$MaxAttempts = 5,
        [int]$DelayMilliseconds = 1000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                Fail "Cannot remove directory after $MaxAttempts attempts: $Path. $($_.Exception.Message)"
            }

            Write-Info ("Directory remove retry {0}/{1}: {2}" -f $attempt, $MaxAttempts, $Path)
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function New-CleanDirectory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-DirectoryWithRetry -Path $Path -MaxAttempts 8 -DelayMilliseconds 1000
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

function Resolve-ArtifactName {
    param(
        [string]$Template,
        [string]$Version,
        [string]$Platform
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        Fail 'Artifact naming template is required'
    }

    return $Template.Replace('{version}', $Version).Replace('{platform}', $Platform)
}

function Build-ReleaseAssetUrl {
    param(
        [string]$Pattern,
        [string]$Tag,
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        Fail 'Manifest releaseAssetUrlPattern is required'
    }

    return $Pattern.Replace('{tag}', $Tag).Replace('{file}', $FileName)
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

function Get-Sha256Hex {
    param([string]$Path)

    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $fileStream = $null
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $fileStream = [System.IO.File]::OpenRead($Path)
        $hashBytes = $sha256.ComputeHash($fileStream)
        $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
        return $hashHex
    }
    finally {
        if ($fileStream) {
            $fileStream.Dispose()
        }
        if ($sha256) {
            $sha256.Dispose()
        }
    }
}

function New-ChecksumFile {
    param(
        [string]$AssetPath,
        [string]$ChecksumPath
    )

    $hash = Get-Sha256Hex -Path $AssetPath
    $assetFileName = Split-Path $AssetPath -Leaf
    $checksumLine = "{0} *{1}" -f $hash, $assetFileName
    $checksumLine | Out-File -FilePath $ChecksumPath -Encoding utf8
    return $hash
}

function Assert-DirectoryWritable {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $probeFile = Join-Path $Path ('.write-test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        'ok' | Out-File -FilePath $probeFile -Encoding ascii -NoNewline
        Remove-Item -LiteralPath $probeFile -Force
    }
    catch {
        Fail "Output directory is not writable: $Path. $($_.Exception.Message)"
    }
}

function Test-FileLocked {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $false
    }
    catch {
        return $true
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Assert-PathLengthLimit {
    param(
        [string]$Root,
        [int]$MaxPathLength = 320
    )

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)
    foreach ($file in $files) {
        if ($file.FullName.Length -gt $MaxPathLength) {
            Fail "Path too long for stable zip operation (>$MaxPathLength chars): $($file.FullName). Move repo closer to drive root or enable long paths."
        }
    }
}

function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [string]$FriendlyName
    )

    $argumentString = ($Arguments -join ' ')
    Write-Info ("Starting {0}: {1} {2}" -f $FriendlyName, $FilePath, $argumentString)

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Best effort kill
        }

        Fail "$FriendlyName timed out after $TimeoutSeconds seconds. Check antivirus/EDR scan, locked files, or reduce payload size."
    }

    $process.Refresh()
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        $exitCode = $process.ExitCode
    }

    if ($null -eq $exitCode) {
        Write-Info "$FriendlyName finished but exit code is unavailable; continuing with artifact validation"
        return
    }

    if ($exitCode -ne 0) {
        Fail "$FriendlyName failed with exit code $exitCode"
    }
}

function Invoke-CanonicalZip {
    param(
        [string]$SourceDir,
        [string]$DestinationPath,
        [int]$TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        Fail "Zip source directory does not exist: $SourceDir"
    }

    if ($TimeoutSeconds -le 0) {
        Fail "ZipTimeoutSeconds must be greater than 0. Received: $TimeoutSeconds"
    }

    $destinationDirectory = Split-Path -Parent $DestinationPath
    Assert-DirectoryWritable -Path $destinationDirectory
    Assert-PathLengthLimit -Root $SourceDir -MaxPathLength 320

    if (Test-Path -LiteralPath $DestinationPath) {
        if (Test-FileLocked -Path $DestinationPath) {
            Fail "Destination zip is locked by another process: $DestinationPath"
        }

        Remove-FileWithRetry -Path $DestinationPath -MaxAttempts 5 -DelayMilliseconds 1000
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force)
    if ($sourceFiles.Count -eq 0) {
        Fail "Zip source directory has no files: $SourceDir"
    }

    Write-Info "Zip source file count: $($sourceFiles.Count)"
    Write-Info "Zip timeout seconds: $TimeoutSeconds"
    $zipStartAt = Get-Date

    $sevenZipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $sevenZipCommand) {
        $sevenZipCommand = Get-Command 7za.exe -ErrorAction SilentlyContinue
    }

    if ($sevenZipCommand) {
        $sevenZipArguments = @('a', '-tzip', '-mx=7', '-mmt=on', '-y', $DestinationPath, '.\*')
        Invoke-ExternalProcess -FilePath $sevenZipCommand.Source -Arguments $sevenZipArguments -WorkingDirectory $SourceDir -TimeoutSeconds $TimeoutSeconds -FriendlyName '7z zip'
    }
    else {
        $workerScriptPath = Join-Path $env:TEMP ('v-claw-zip-' + [Guid]::NewGuid().ToString('N') + '.ps1')
        $workerScript = @'
param(
    [string]$SourceDir,
    [string]$DestinationPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $SourceDir,
    $DestinationPath,
    [System.IO.Compression.CompressionLevel]::Fastest,
    $false
)
'@

        try {
            $workerScript | Out-File -FilePath $workerScriptPath -Encoding utf8
            $workerArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $workerScriptPath, '-SourceDir', $SourceDir, '-DestinationPath', $DestinationPath)
            Invoke-ExternalProcess -FilePath 'powershell.exe' -Arguments $workerArguments -WorkingDirectory $SourceDir -TimeoutSeconds $TimeoutSeconds -FriendlyName 'dotnet zip worker'
        }
        finally {
            if (Test-Path -LiteralPath $workerScriptPath) {
                Remove-FileWithRetry -Path $workerScriptPath -MaxAttempts 3 -DelayMilliseconds 300
            }
        }
    }

    $zipDurationSeconds = [math]::Round(((Get-Date) - $zipStartAt).TotalSeconds, 2)
    Write-Info "Zip duration seconds: $zipDurationSeconds"

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        Fail "Zip output was not created: $DestinationPath"
    }

    $zipSize = (Get-Item -LiteralPath $DestinationPath).Length
    if ($zipSize -le 0) {
        Fail "Zip output was created but is empty: $DestinationPath"
    }

    if (Test-FileLocked -Path $DestinationPath) {
        Fail "Zip output was created but remains locked: $DestinationPath"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$resolvedManifestPath = if ($ManifestPath) { $ManifestPath } else { Join-Path $scriptDir 'bundle-manifest.json' }
$resolvedOutputDir = if ($OutputDir) { $OutputDir } else { Join-Path $repoRoot 'dist' }

$resolvedManifestPath = (Resolve-Path $resolvedManifestPath).Path
$manifest = Get-JsonObject -Path $resolvedManifestPath

$bundleName = [string]$manifest.bundleName
$bundleVersion = [string]$manifest.bundleVersion
$platform = [string]$manifest.platform
$bundleRepo = [string]$manifest.bundleRepo
$manifestName = [string]$manifest.manifestName
$releaseTag = [string]$manifest.releaseTag
$releaseAssetUrlPattern = [string]$manifest.releaseAssetUrlPattern
$dependencies = ConvertTo-OrderedMap -InputObject $manifest.dependencies
$requiredPaths = @($manifest.requiredPaths)
$stagePackageName = [string]$manifest.stagePackage.name
$stagePackageDescription = [string]$manifest.stagePackage.description
$stagePackagePrivate = [bool]$manifest.stagePackage.private
$coreArtifactTemplate = [string]$manifest.artifactNaming.core
$forbiddenDependencies = @()
if ($manifest.PSObject.Properties.Name -contains 'forbiddenDependencies' -and $null -ne $manifest.forbiddenDependencies) {
    $forbiddenDependencies = @($manifest.forbiddenDependencies)
}

if ([string]::IsNullOrWhiteSpace($bundleName)) {
    Fail 'Manifest bundleName is required'
}
if ([string]::IsNullOrWhiteSpace($bundleVersion)) {
    Fail 'Manifest bundleVersion is required'
}
if ([string]::IsNullOrWhiteSpace($platform)) {
    Fail 'Manifest platform is required'
}
if ([string]::IsNullOrWhiteSpace($bundleRepo)) {
    Fail 'Manifest bundleRepo is required'
}
if ([string]::IsNullOrWhiteSpace($manifestName)) {
    Fail 'Manifest manifestName is required'
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
    $stagePackageDescription = 'Canonical V-Claw core bundle payload'
}
if ([string]::IsNullOrWhiteSpace($releaseTag)) {
    $releaseTag = "v$bundleVersion"
}

$coreAssetName = Resolve-ArtifactName -Template $coreArtifactTemplate -Version $bundleVersion -Platform $platform
$checksumName = "$coreAssetName.sha256"

Assert-CommandExists -Name 'npm'

if ($ZipTimeoutSeconds -le 0) {
    Fail "ZipTimeoutSeconds must be greater than 0. Received: $ZipTimeoutSeconds"
}

$resolvedOutputDir = [System.IO.Path]::GetFullPath($resolvedOutputDir)
$stageDir = Join-Path $resolvedOutputDir $bundleName
$assetPath = Join-Path $resolvedOutputDir $coreAssetName
$checksumPath = Join-Path $resolvedOutputDir $checksumName
$coreManifestPath = Join-Path $resolvedOutputDir $manifestName

if ($Clean) {
    Write-Info "Cleaning output directory: $resolvedOutputDir"
    New-CleanDirectory -Path $resolvedOutputDir
}
else {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
    if (Test-Path -LiteralPath $stageDir) {
        Remove-DirectoryWithRetry -Path $stageDir -MaxAttempts 8 -DelayMilliseconds 1000
    }
}

if (Test-Path -LiteralPath $assetPath) {
    Remove-FileWithRetry -Path $assetPath -MaxAttempts 5 -DelayMilliseconds 1000
}
if (Test-Path -LiteralPath $checksumPath) {
    Remove-FileWithRetry -Path $checksumPath -MaxAttempts 5 -DelayMilliseconds 1000
}
if (Test-Path -LiteralPath $coreManifestPath) {
    Remove-FileWithRetry -Path $coreManifestPath -MaxAttempts 5 -DelayMilliseconds 1000
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
& npm install --prefix $stageDir --omit=dev --ignore-scripts --no-fund --no-audit --no-progress
if ($LASTEXITCODE -ne 0) {
    Fail 'npm install failed while building v-claw-bundle'
}

Assert-ForbiddenDependenciesAbsent -Root $stageDir -PackageNames $forbiddenDependencies
Assert-PathExists -Root $stageDir -RelativePaths $requiredPaths

Write-Info "Creating canonical core bundle archive: $assetPath"
Invoke-CanonicalZip -SourceDir $stageDir -DestinationPath $assetPath -TimeoutSeconds $ZipTimeoutSeconds
Write-Ok "Canonical zip completed: $assetPath"

$sha256 = New-ChecksumFile -AssetPath $assetPath -ChecksumPath $checksumPath
$assetSizeBytes = (Get-Item $assetPath).Length
$assetUrl = Build-ReleaseAssetUrl -Pattern $releaseAssetUrlPattern -Tag $releaseTag -FileName $coreAssetName

$coreManifest = [ordered]@{
    manifestVersion       = 1
    bundleName            = $bundleName
    bundleVersion         = $bundleVersion
    releaseTag            = $releaseTag
    bundleRepo            = $bundleRepo
    generatedAt           = (Get-Date).ToUniversalTime().ToString('o')
    releaseAssetUrlPattern = $releaseAssetUrlPattern
    artifactNaming        = [ordered]@{
        core = $coreArtifactTemplate
    }
    artifacts             = [ordered]@{
        $platform = [ordered]@{
            core = [ordered]@{
                file      = $coreAssetName
                sha256    = $sha256
                sizeBytes = $assetSizeBytes
                url       = $assetUrl
            }
        }
    }
}

$coreManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $coreManifestPath -Encoding utf8

Write-Ok "Bundle staged at: $stageDir"
Write-Ok "Core bundle asset: $assetPath"
Write-Ok "Checksum: $checksumPath"
Write-Ok "Core manifest: $coreManifestPath"

