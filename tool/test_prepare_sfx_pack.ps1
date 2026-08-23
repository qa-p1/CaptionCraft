[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Process {
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start '$Executable'."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject] @{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-ClearanceManifest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [Parameter()] [string] $License = 'CC0-1.0',
        [Parameter()] [string] $SourceUrl = 'https://example.test/sounds/interface-click'
    )

    $document = [ordered] @{
        schema = 'captioncraft-sfx-clearance-manifest'
        schemaVersion = 1
        pack = [ordered] @{
            id = 'sound-effects'
            title = 'Fixture Sound Effects'
        }
        review = [ordered] @{
            redistributionRightsConfirmed = $true
            reviewedBy = 'CaptionCraft fixture'
            reviewedAtUtc = '2026-08-11T00:00:00Z'
        }
        assets = @(
            [ordered] @{
                id = 'interface-click-001'
                title = 'Interface Click'
                categoryId = 'interface'
                categoryName = 'Interface'
                sourcePath = 'interface/click.wav'
                expectedSha256 = $ExpectedSha256
                license = $License
                licenseUrl = 'https://creativecommons.org/publicdomain/zero/1.0/'
                sourceUrl = $SourceUrl
                creator = 'CaptionCraft fixture'
                attribution = 'Synthetic test tone; not a release asset.'
                redistributionCleared = $true
                tags = @('click', 'ui')
            }
        )
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        $Path,
        "$(($document | ConvertTo-Json -Depth 10))`n",
        $utf8NoBom
    )
}

function Invoke-Validation {
    param(
        [Parameter(Mandatory)] [string] $Pwsh,
        [Parameter(Mandatory)] [string] $Pipeline,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Manifest
    )

    return Invoke-Process -Executable $Pwsh -Arguments @(
        '-NoProfile',
        '-File', $Pipeline,
        '-SourceRoot', $Source,
        '-ClearanceManifest', $Manifest,
        '-Version', '0.0.0-fixture',
        '-ValidateOnly'
    )
}

function Invoke-Preparation {
    param(
        [Parameter(Mandatory)] [string] $Pwsh,
        [Parameter(Mandatory)] [string] $Pipeline,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Manifest
    )

    return Invoke-Process -Executable $Pwsh -Arguments @(
        '-NoProfile',
        '-File', $Pipeline,
        '-SourceRoot', $Source,
        '-ClearanceManifest', $Manifest,
        '-Version', '0.0.0-fixture'
    )
}

function Assert-Succeeded {
    param(
        [Parameter(Mandatory)] [object] $Result,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Result.exitCode -ne 0) {
        throw "$Description failed unexpectedly.`nSTDOUT:`n$($Result.stdout)`nSTDERR:`n$($Result.stderr)"
    }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)] [object] $Result,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Result.exitCode -eq 0) {
        throw "$Description was accepted unexpectedly."
    }
    $combined = "$($Result.stdout)`n$($Result.stderr)"
    if ($combined -notmatch $Pattern) {
        throw "$Description failed for the wrong reason.`n$combined"
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pipeline = Join-Path $PSScriptRoot 'prepare_sfx_pack.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$reservedVersion = '0.0.0-fixture'
$reservedTargets = @(
    (Join-Path $repoRoot "tool\asset_pack_staging\sound-effects\$reservedVersion"),
    (Join-Path $repoRoot "tool\asset_pack_dist\packs\sound-effects\$reservedVersion")
)
foreach ($target in $reservedTargets) {
    if (Test-Path -LiteralPath $target) {
        throw "Fixture will not run because its reserved generated target already exists: '$target'."
    }
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "captioncraft-sfx-pipeline-$([guid]::NewGuid().ToString('N'))"
$sourceRoot = Join-Path $fixtureRoot 'source'
$audioDirectory = Join-Path $sourceRoot 'interface'
$audioPath = Join-Path $audioDirectory 'click.wav'
$manifestPath = Join-Path $fixtureRoot 'clearance.json'
[void] [System.IO.Directory]::CreateDirectory($audioDirectory)

try {
    $generate = Invoke-Process -Executable $ffmpeg -Arguments @(
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi',
        '-i', 'sine=frequency=440:duration=0.12',
        '-c:a', 'pcm_s16le',
        '-ar', '48000',
        '-ac', '1',
        $audioPath
    )
    Assert-Succeeded -Result $generate -Description 'Synthetic WAV generation'
    $sha256 = (Get-FileHash -LiteralPath $audioPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-ClearanceManifest -Path $manifestPath -ExpectedSha256 $sha256
    $valid = Invoke-Validation -Pwsh $pwsh -Pipeline $pipeline -Source $sourceRoot -Manifest $manifestPath
    Assert-Succeeded -Result $valid -Description 'Valid rights-cleared fixture validation'
    if ($valid.stdout -notmatch 'ValidateOnly created no staging files') {
        throw "Valid fixture did not report its no-write guarantee.`n$($valid.stdout)"
    }

    # Exercise the release-writing branch only inside this disposable fake
    # repository, never inside the actual CaptionCraft staging directories.
    $isolatedToolDirectory = Join-Path $fixtureRoot 'isolated-repo\tool'
    [void] [System.IO.Directory]::CreateDirectory($isolatedToolDirectory)
    $isolatedPipeline = Join-Path $isolatedToolDirectory 'prepare_sfx_pack.ps1'
    [System.IO.File]::Copy($pipeline, $isolatedPipeline, $false)
    $prepared = Invoke-Preparation -Pwsh $pwsh -Pipeline $isolatedPipeline -Source $sourceRoot -Manifest $manifestPath
    Assert-Succeeded -Result $prepared -Description 'Isolated synthetic release preparation'

    $isolatedStaging = Join-Path $fixtureRoot 'isolated-repo\tool\asset_pack_staging\sound-effects\0.0.0-fixture'
    $isolatedDistribution = Join-Path $fixtureRoot 'isolated-repo\tool\asset_pack_dist\packs\sound-effects\0.0.0-fixture'
    $catalogPath = Join-Path $isolatedStaging 'db.json'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw 'Isolated preparation did not produce db.json.'
    }
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $catalogAsset = @($catalog.assets)[0]
    if (
        $catalog.schemaVersion -ne 3 -or
        $catalog.pack.id -cne 'sound-effects' -or
        $catalogAsset.mediaType -cne 'audio' -or
        [long] $catalogAsset.durationMs -le 0 -or
        [int] $catalogAsset.metadata.sampleRate -le 0 -or
        [int] $catalogAsset.metadata.channels -le 0 -or
        $catalogAsset.metadata.redistributionCleared -ne $true -or
        $catalogAsset.metadata.attribution -cne 'Synthetic test tone; not a release asset.' -or
        $catalogAsset.metadata.provenance.sourceSha256 -cne $sha256
    ) {
        throw 'Isolated preparation produced an invalid schema-v3 audio catalog.'
    }

    $archives = @(Get-ChildItem -LiteralPath $isolatedDistribution -Filter '*.zip' -File)
    $releaseFiles = @(Get-ChildItem -LiteralPath $isolatedDistribution -Filter '*.release.json' -File)
    if ($archives.Count -ne 1 -or $releaseFiles.Count -ne 1) {
        throw 'Isolated preparation did not produce exactly one ZIP and one release JSON.'
    }
    $release = Get-Content -LiteralPath $releaseFiles[0].FullName -Raw | ConvertFrom-Json
    $archiveSha256 = (Get-FileHash -LiteralPath $archives[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $releasePart = @($release.pack.parts)[0]
    if (
        $release.schemaVersion -ne 2 -or
        @($release.pack.parts).Count -ne 1 -or
        $releasePart.sha256 -cne $archiveSha256 -or
        [long] $releasePart.bytes -ne [long] $archives[0].Length -or
        [int] $release.pack.assetCount -ne 1 -or
        $archives[0].Name -notmatch [regex]::Escape($archiveSha256.Substring(0, 12))
    ) {
        throw 'Isolated release metadata does not match its content-addressed ZIP.'
    }
    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archives[0].FullName)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        if ($entryNames -notcontains 'db.json' -or $entryNames -notcontains 'sounds/interface/interface-click-001.wav') {
            throw 'Isolated ZIP is missing its catalog or normalized audio entry.'
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-ClearanceManifest -Path $manifestPath -ExpectedSha256 $sha256 -License 'unlicensed'
    $unlicensed = Invoke-Validation -Pwsh $pwsh -Pipeline $pipeline -Source $sourceRoot -Manifest $manifestPath
    Assert-Rejected -Result $unlicensed -Pattern '(?i)unlicensed' -Description 'Unlicensed fixture'

    foreach ($marker in @('y2mate', 'Fairlight')) {
        Write-ClearanceManifest -Path $manifestPath -ExpectedSha256 $sha256 -SourceUrl "https://example.test/$marker/interface-click"
        $forbidden = Invoke-Validation -Pwsh $pwsh -Pipeline $pipeline -Source $sourceRoot -Manifest $manifestPath
        Assert-Rejected -Result $forbidden -Pattern '(?i)forbidden.*provenance' -Description "$marker provenance fixture"
    }

    Write-ClearanceManifest -Path $manifestPath -ExpectedSha256 $sha256
    [System.IO.File]::Copy($audioPath, (Join-Path $audioDirectory 'undeclared.wav'), $false)
    $undeclared = Invoke-Validation -Pwsh $pwsh -Pipeline $pipeline -Source $sourceRoot -Manifest $manifestPath
    Assert-Rejected -Result $undeclared -Pattern '(?i)not declared.*unlicensed' -Description 'Undeclared audio fixture'

    foreach ($target in $reservedTargets) {
        if (Test-Path -LiteralPath $target) {
            throw "ValidateOnly unexpectedly created generated output '$target'."
        }
    }

    Write-Host 'prepare_sfx_pack fixture passed:'
    Write-Host '  accepted a hash-bound, rights-cleared synthetic WAV'
    Write-Host '  verified schema-v3 catalog, cacheable ZIP part, and schema-v2 release metadata in OS temp'
    Write-Host '  rejected unlicensed, Fairlight, y2mate, and undeclared inputs'
    Write-Host '  confirmed the real repository received no staging or distribution output'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        [System.IO.Directory]::Delete($fixtureRoot, $true)
    }
}
