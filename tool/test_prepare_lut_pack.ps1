[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

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

function Assert-Succeeded {
    param(
        [Parameter(Mandatory)] [object] $Result,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Result.exitCode -ne 0) {
        throw "$Description failed.`nSTDOUT:`n$($Result.stdout)`nSTDERR:`n$($Result.stderr)"
    }
}

$pipeline = Join-Path $PSScriptRoot 'prepare_lut_pack.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "captioncraft-lut-pipeline-$([guid]::NewGuid().ToString('N'))"
$sourceRoot = Join-Path $fixtureRoot 'source'
$filmDirectory = Join-Path $sourceRoot 'film'
$lutPath = Join-Path $filmDirectory 'fixture.cube'
$previewPath = Join-Path $fixtureRoot 'preview.png'
$manifestPath = Join-Path $fixtureRoot 'manifest.json'
[void] [System.IO.Directory]::CreateDirectory($filmDirectory)

try {
    $cube = @'
TITLE "Fixture"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.0 0.0 0.0
0.0 0.0 1.0
0.0 1.0 0.0
0.0 1.0 1.0
1.0 0.0 0.0
1.0 0.0 1.0
1.0 1.0 0.0
1.0 1.0 1.0
'@
    [System.IO.File]::WriteAllText($lutPath, "$cube`n", $utf8NoBom)
    $generated = Invoke-Process -Executable $ffmpeg -Arguments @(
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=640x360:duration=0.1',
        '-frames:v', '1', $previewPath
    )
    Assert-Succeeded -Result $generated -Description 'Preview fixture generation'
    $lutSha256 = (Get-FileHash -LiteralPath $lutPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $previewSha256 = (Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered] @{
        schema = 'captioncraft-lut-source-manifest'
        schemaVersion = 1
        pack = [ordered] @{
            id = 'luts'
            title = 'Fixture LUTs'
        }
        review = [ordered] @{
            redistributionRightsConfirmed = $true
            reviewedBy = 'CaptionCraft fixture'
            reviewedAtUtc = '2026-08-29T00:00:00Z'
        }
        preview = [ordered] @{
            expectedSha256 = $previewSha256
            license = 'CC0-1.0'
            licenseUrl = 'https://creativecommons.org/publicdomain/zero/1.0/'
            sourceUrl = 'https://example.test/preview-source'
            redistributionCleared = $true
        }
        assets = @(
            [ordered] @{
                id = 'fixture-film-look'
                title = 'Fixture Film Look'
                categoryId = 'film'
                categoryName = 'Film'
                sourcePath = 'film/fixture.cube'
                expectedSha256 = $lutSha256
                license = 'CC0-1.0'
                licenseUrl = 'https://creativecommons.org/publicdomain/zero/1.0/'
                sourceUrl = 'https://example.test/fixture-lut'
                redistributionCleared = $true
                tags = @('film', 'fixture')
            }
        )
    }
    [System.IO.File]::WriteAllText(
        $manifestPath,
        "$(($manifest | ConvertTo-Json -Depth 12))`n",
        $utf8NoBom
    )

    $validate = Invoke-Process -Executable $pwsh -Arguments @(
        '-NoProfile', '-File', $pipeline,
        '-SourceRoot', $sourceRoot,
        '-PackManifest', $manifestPath,
        '-PreviewSource', $previewPath,
        '-Version', '0.0.0-fixture',
        '-ValidateOnly'
    )
    Assert-Succeeded -Result $validate -Description 'LUT validation fixture'
    if ($validate.stdout -notmatch 'ValidateOnly created no staging files') {
        throw 'ValidateOnly did not report its no-staging guarantee.'
    }

    $isolatedTool = Join-Path $fixtureRoot 'isolated-repo\tool'
    [void] [System.IO.Directory]::CreateDirectory($isolatedTool)
    $isolatedPipeline = Join-Path $isolatedTool 'prepare_lut_pack.ps1'
    [System.IO.File]::Copy($pipeline, $isolatedPipeline, $false)
    $prepare = Invoke-Process -Executable $pwsh -Arguments @(
        '-NoProfile', '-File', $isolatedPipeline,
        '-SourceRoot', $sourceRoot,
        '-PackManifest', $manifestPath,
        '-PreviewSource', $previewPath,
        '-Version', '0.0.0-fixture'
    )
    Assert-Succeeded -Result $prepare -Description 'Isolated LUT release fixture'

    $staging = Join-Path $fixtureRoot 'isolated-repo\tool\asset_pack_staging\luts\0.0.0-fixture'
    $distribution = Join-Path $fixtureRoot 'isolated-repo\tool\asset_pack_dist\packs\luts\0.0.0-fixture'
    $catalog = Get-Content -LiteralPath (Join-Path $staging 'db.json') -Raw | ConvertFrom-Json
    $asset = @($catalog.assets)[0]
    $previewFile = Join-Path $staging ([string] $asset.previewPath).Replace('/', '\')
    $lutFile = Join-Path $staging ([string] $asset.relativePath).Replace('/', '\')
    if (
        $catalog.schemaVersion -ne 3 -or
        $catalog.pack.id -cne 'luts' -or
        $asset.mediaType -cne 'lut' -or
        [int] $asset.metadata.gridSize -ne 2 -or
        -not (Test-Path -LiteralPath $previewFile -PathType Leaf) -or
        -not (Test-Path -LiteralPath $lutFile -PathType Leaf)
    ) {
        throw 'Prepared LUT catalog is invalid.'
    }
    $archives = @(Get-ChildItem -LiteralPath $distribution -Filter '*.zip' -File)
    $releases = @(Get-ChildItem -LiteralPath $distribution -Filter '*.release.json' -File)
    if ($archives.Count -ne 1 -or $releases.Count -ne 1) {
        throw 'LUT preparation did not produce one archive and release descriptor.'
    }
    $release = Get-Content -LiteralPath $releases[0].FullName -Raw | ConvertFrom-Json
    $archiveSha256 = (Get-FileHash -LiteralPath $archives[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $part = @($release.pack.parts)[0]
    if (
        $release.schemaVersion -ne 2 -or
        $release.pack.id -cne 'luts' -or
        $part.sha256 -cne $archiveSha256 -or
        [long] $part.bytes -ne [long] $archives[0].Length -or
        [int] $release.pack.assetCount -ne 1
    ) {
        throw 'LUT release descriptor does not match its archive.'
    }
    Write-Host 'prepare_lut_pack fixture passed: validation, preview, catalog, archive, and release verified.'
}
finally {
    if ([System.IO.Directory]::Exists($fixtureRoot)) {
        [System.IO.Directory]::Delete($fixtureRoot, $true)
    }
}
