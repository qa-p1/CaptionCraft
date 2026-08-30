[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixtureRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) "captioncraft-manifest-$([guid]::NewGuid().ToString('N'))"
$composer = Join-Path $PSScriptRoot 'compose_asset_pack_manifest.ps1'

function New-PackRow {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [char] $DigestCharacter
    )

    return [ordered] @{
        id = $Id
        version = '1.0.0'
        title = $Title
        description = "Fixture descriptor for $Title."
        assetCount = 2
        installedBytes = 2048
        catalogPath = 'db.json'
        catalogSchemaVersion = 3
        minAppBuild = 1
        parts = @(
            [ordered] @{
                id = 'part-001'
                url = "$Id/fixture.part-001.zip"
                sha256 = ([string] $DigestCharacter) * 64
                bytes = 1024
            }
        )
    }
}

[void] [System.IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $basePath = Join-Path $fixtureRoot 'base.json'
    $sfxPath = Join-Path $fixtureRoot 'sfx.json'
    $lutPath = Join-Path $fixtureRoot 'luts.json'
    $outputPath = Join-Path $fixtureRoot 'asset-pack-manifest.json'
    $lutOnlyOutputPath = Join-Path $fixtureRoot 'asset-pack-manifest.with-luts.json'

    $base = [ordered] @{
        schemaVersion = 2
        packs = @(
            (New-PackRow -Id 'background-videos' -Title 'Background Videos' -DigestCharacter 'a'),
            (New-PackRow -Id 'overlays' -Title 'Overlays' -DigestCharacter 'b')
        )
    }
    $sfx = [ordered] @{
        schema = 'captioncraft-asset-pack-release'
        schemaVersion = 2
        pack = New-PackRow -Id 'sound-effects' -Title 'Sound Effects' -DigestCharacter 'c'
    }
    $luts = [ordered] @{
        schema = 'captioncraft-asset-pack-release'
        schemaVersion = 2
        pack = New-PackRow -Id 'luts' -Title 'LUTs' -DigestCharacter 'd'
    }

    [System.IO.File]::WriteAllText(
        $basePath,
        (($base | ConvertTo-Json -Depth 12) + "`n"),
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        $sfxPath,
        (($sfx | ConvertTo-Json -Depth 12) + "`n"),
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        $lutPath,
        (($luts | ConvertTo-Json -Depth 12) + "`n"),
        $utf8NoBom
    )

    & $composer `
        -BaseManifest $basePath `
        -SfxRelease $sfxPath `
        -LutRelease $lutPath `
        -OutputPath $outputPath
    $result = [System.IO.File]::ReadAllText($outputPath) | ConvertFrom-Json
    $ids = @($result.packs | ForEach-Object { [string] $_.id })
    if (
        [int] $result.schemaVersion -ne 2 -or
        $ids.Count -ne 4 -or
        $ids -cnotcontains 'background-videos' -or
        $ids -cnotcontains 'overlays' -or
        $ids -cnotcontains 'sound-effects' -or
        $ids -cnotcontains 'luts'
    ) {
        throw 'Composer did not produce one validated row for every supported pack.'
    }

    & $composer `
        -BaseManifest $basePath `
        -LutRelease $lutPath `
        -OutputPath $lutOnlyOutputPath
    $lutOnly = [System.IO.File]::ReadAllText($lutOnlyOutputPath) | ConvertFrom-Json
    $lutOnlyIds = @($lutOnly.packs | ForEach-Object { [string] $_.id })
    if (
        $lutOnlyIds.Count -ne 3 -or
        $lutOnlyIds -cnotcontains 'background-videos' -or
        $lutOnlyIds -cnotcontains 'overlays' -or
        $lutOnlyIds -cnotcontains 'luts' -or
        $lutOnlyIds -ccontains 'sound-effects'
    ) {
        throw 'Composer could not add a LUT release independently of SFX.'
    }

    $refusedOverwrite = $false
    try {
        & $composer `
            -BaseManifest $basePath `
            -SfxRelease $sfxPath `
            -LutRelease $lutPath `
            -OutputPath $outputPath
    }
    catch {
        $refusedOverwrite = $_.Exception.Message -like 'Refusing to overwrite*'
    }
    if (-not $refusedOverwrite) {
        throw 'Composer did not protect an existing manifest from overwrite.'
    }

    Write-Host 'compose_asset_pack_manifest fixture passed: optional releases and atomic overwrite guard verified.'
}
finally {
    if ([System.IO.Directory]::Exists($fixtureRoot)) {
        [System.IO.Directory]::Delete($fixtureRoot, $true)
    }
}
