[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $BaseManifest,

    [Parameter()]
    [string] $SfxRelease,

    [Parameter()]
    [string] $LutRelease,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$maximumPartBytes = 503316480L
$supportedIds = @('background-videos', 'overlays', 'sound-effects', 'luts')

function Read-JsonObject {
    param([Parameter(Mandatory)] [string] $Path)

    $resolved = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    )
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "JSON input is not a file: '$resolved'."
    }
    try {
        return [System.IO.File]::ReadAllText($resolved) | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Assert-PackRow {
    param(
        [Parameter(Mandatory)] [object] $Pack,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Ids
    )

    $id = [string] $Pack.id
    if ($supportedIds -cnotcontains $id -or -not $Ids.Add($id)) {
        throw "Unsupported or duplicate asset pack id '$id'."
    }
    if (
        [string]::IsNullOrWhiteSpace([string] $Pack.version) -or
        [string]::IsNullOrWhiteSpace([string] $Pack.title) -or
        [string]::IsNullOrWhiteSpace([string] $Pack.catalogPath) -or
        [long] $Pack.installedBytes -le 0 -or
        [int] $Pack.assetCount -le 0 -or
        [int] $Pack.catalogSchemaVersion -ne 3
    ) {
        throw "Pack '$id' is missing required schema-v2 descriptor fields."
    }
    $partIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $parts = @($Pack.parts)
    if ($parts.Count -eq 0 -or $parts.Count -gt 64) {
        throw "Pack '$id' has an invalid archive part count."
    }
    foreach ($part in $parts) {
        $partId = [string] $part.id
        $url = [string] $part.url
        $digest = [string] $part.sha256
        $bytes = [long] $part.bytes
        if (
            [string]::IsNullOrWhiteSpace($partId) -or
            -not $partIds.Add($partId) -or
            [string]::IsNullOrWhiteSpace($url) -or
            $url.Contains('..') -or
            $digest -cnotmatch '^[a-f0-9]{64}$' -or
            $bytes -le 0 -or
            $bytes -gt $maximumPartBytes
        ) {
            throw "Pack '$id' contains an invalid archive part."
        }
    }
}

$base = Read-JsonObject -Path $BaseManifest
if ([int] $base.schemaVersion -ne 2) {
    throw 'Base asset-pack manifest must use schema version 2.'
}

$replacements = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::Ordinal
)
if (-not [string]::IsNullOrWhiteSpace($SfxRelease)) {
    $sfx = Read-JsonObject -Path $SfxRelease
    if (
        [string] $sfx.schema -cne 'captioncraft-asset-pack-release' -or
        [int] $sfx.schemaVersion -ne 2 -or
        [string] $sfx.pack.id -cne 'sound-effects'
    ) {
        throw 'SFX release JSON is not a schema-v2 sound-effects release.'
    }
    $replacements.Add('sound-effects', $sfx.pack)
}
if (-not [string]::IsNullOrWhiteSpace($LutRelease)) {
    $luts = Read-JsonObject -Path $LutRelease
    if (
        [string] $luts.schema -cne 'captioncraft-asset-pack-release' -or
        [int] $luts.schemaVersion -ne 2 -or
        [string] $luts.pack.id -cne 'luts'
    ) {
        throw 'LUT release JSON is not a schema-v2 luts release.'
    }
    $replacements.Add('luts', $luts.pack)
}
if ($replacements.Count -eq 0) {
    throw 'Provide at least one SfxRelease or LutRelease to compose.'
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($pack in @($base.packs)) {
    if (-not $replacements.ContainsKey([string] $pack.id)) {
        $rows.Add($pack)
    }
}
foreach ($replacementId in @($replacements.Keys | Sort-Object)) {
    $rows.Add($replacements[$replacementId])
}

$ids = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($row in $rows) {
    Assert-PackRow -Pack $row -Ids $ids
}
foreach ($requiredId in @('background-videos', 'overlays')) {
    if (-not $ids.Contains($requiredId)) {
        throw "Composed manifest is missing '$requiredId'."
    }
}
foreach ($replacementId in $replacements.Keys) {
    if (-not $ids.Contains($replacementId)) {
        throw "Composed manifest is missing replacement '$replacementId'."
    }
}

$outputFull = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "Refusing to overwrite output manifest '$outputFull'."
}
$parent = [System.IO.Path]::GetDirectoryName($outputFull)
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [void] [System.IO.Directory]::CreateDirectory($parent)
}
$temporary = "$outputFull.part-$PID"
try {
    $json = [ordered] @{
        schemaVersion = 2
        packs = $rows.ToArray()
    } | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($temporary, "$json`n", $utf8NoBom)
    [System.IO.File]::Move($temporary, $outputFull)
}
finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        [System.IO.File]::Delete($temporary)
    }
}

Write-Host "Composed $($rows.Count)-pack manifest: $outputFull"
