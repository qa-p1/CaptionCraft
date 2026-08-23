[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ClearanceManifest,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '1.0.0',

    [Parameter()]
    [ValidateRange(1048576, 503316480)]
    [long] $MaxPartBytes = 471859200,

    # Performs the complete clearance, hash, and ffprobe validation without
    # creating staging files, a ZIP, or release metadata.
    [Parameter()]
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:FixedZipTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$script:ForbiddenProvenancePattern = '(?i)(?:fairlight|y2mate)'
$script:StableIdPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
$script:SupportedAudioExtensions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($extension in @('.aac', '.aif', '.aiff', '.caf', '.flac', '.m4a', '.mp3', '.ogg', '.opus', '.wav', '.webm')) {
    [void] $script:SupportedAudioExtensions.Add($extension)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value,
        [Parameter()] [int] $Depth = 16
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, "$json`n", $script:Utf8NoBom)
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PathComparison {
    if ([System.OperatingSystem]::IsWindows()) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

function Get-PathComparer {
    if ([System.OperatingSystem]::IsWindows()) {
        return [System.StringComparer]::OrdinalIgnoreCase
    }
    return [System.StringComparer]::Ordinal
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Test-IsPathWithin {
    param(
        [Parameter(Mandatory)] [string] $Parent,
        [Parameter(Mandatory)] [string] $Candidate
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ($candidateFull.Equals($parentFull, (Get-PathComparison))) {
        return $true
    }
    $prefix = "$parentFull$([System.IO.Path]::DirectorySeparatorChar)"
    return $candidateFull.StartsWith($prefix, (Get-PathComparison))
}

function Resolve-SafeChildPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $portable = $RelativePath.Trim().Replace('\', '/')
    $segments = $portable.Split('/')
    if (
        [string]::IsNullOrWhiteSpace($portable) -or
        $portable.StartsWith('/') -or
        $portable.Contains(':') -or
        $segments.Contains('.') -or
        $segments.Contains('..') -or
        $segments.Contains('')
    ) {
        throw "Unsafe sourcePath '$RelativePath'. Use a normalized relative file path."
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $nativeRelative = $portable.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $nativeRelative))
    $prefix = "$rootFull$([System.IO.Path]::DirectorySeparatorChar)"
    if (-not $resolved.StartsWith($prefix, (Get-PathComparison))) {
        throw "sourcePath '$RelativePath' escapes the source root."
    }
    return $resolved
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "$Context is missing '$Name'."
    }
    # Keep JSON arrays intact when this helper returns through PowerShell's
    # success pipeline (including single-item arrays).
    return ,$Object.$Name
}

function Get-OptionalProperty {
    param(
        [Parameter()] [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) {
        return $null
    }
    return ,$Object.$Name
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )

    $value = Get-RequiredProperty -Object $Object -Name $Name -Context $Context
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        throw "$Context has an invalid or empty '$Name'."
    }
    return $value.Trim()
}

function Assert-ExactTrue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )

    $value = Get-RequiredProperty -Object $Object -Name $Name -Context $Context
    if ($value -isnot [bool] -or -not $value) {
        throw "$Context must declare '$Name' as the JSON boolean true."
    }
}

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Field,
        [Parameter(Mandatory)] [string] $Context
    )

    $uri = $null
    if (
        -not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -cne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host)
    ) {
        throw "$Context has an invalid '$Field'. An absolute HTTPS URL is required."
    }
}

function Assert-NoForbiddenProvenance {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [string] $Context
    )

    if ($Value -match $script:ForbiddenProvenancePattern) {
        throw "$Context contains a forbidden Fairlight/y2mate provenance marker. This input cannot be prepared."
    }
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory)] [string] $Root)

    $reparsePoint = Get-ChildItem -LiteralPath $Root -Force -Recurse |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "Source trees containing links or reparse points are not accepted: '$($reparsePoint.FullName)'."
    }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)

    $rows = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -File | Sort-Object FullName)
    foreach ($file in $files) {
        $rows.Add([pscustomobject] [ordered] @{
            relativePath = Get-RelativePath -Root $Root -Path $file.FullName
            sizeBytes = [long] $file.Length
            lastWriteUtcTicks = [long] $file.LastWriteTimeUtc.Ticks
            sha256 = Get-Sha256 -Path $file.FullName
        })
    }
    return $rows.ToArray()
}

function Get-SnapshotDigest {
    param([Parameter(Mandatory)] [object[]] $Snapshot)

    $lines = foreach ($row in $Snapshot) {
        "$($row.relativePath)`t$($row.sizeBytes)`t$($row.lastWriteUtcTicks)`t$($row.sha256)`n"
    }
    $bytes = $script:Utf8NoBom.GetBytes(($lines -join ''))
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Assert-SnapshotsEqual {
    param(
        [Parameter(Mandatory)] [object[]] $Expected,
        [Parameter(Mandatory)] [object[]] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "The source tree changed during preparation (file count differs)."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $left = $Expected[$index]
        $right = $Actual[$index]
        if (
            $left.relativePath -cne $right.relativePath -or
            $left.sizeBytes -ne $right.sizeBytes -or
            $left.lastWriteUtcTicks -ne $right.lastWriteUtcTicks -or
            $left.sha256 -cne $right.sha256
        ) {
            throw "The source tree changed during preparation at '$($left.relativePath)'."
        }
    }
}

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Description
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
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = $stdout.Trim()
            }
            throw "$Description failed with exit code $($process.ExitCode): $detail"
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

function Get-PositiveDouble {
    param([Parameter()] [AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return $null
    }
    $parsed = 0.0
    if (
        [double]::TryParse(
            [string] $Value,
            [System.Globalization.NumberStyles]::Float,
            $script:InvariantCulture,
            [ref] $parsed
        ) -and
        [double]::IsFinite($parsed) -and
        $parsed -gt 0
    ) {
        return $parsed
    }
    return $null
}

function Get-PositiveInt {
    param([Parameter()] [AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return $null
    }
    $parsed = 0
    if ([int]::TryParse([string] $Value, [ref] $parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return $null
}

function Get-AudioMimeType {
    param([Parameter(Mandatory)] [string] $Extension)

    switch ($Extension.ToLowerInvariant()) {
        '.aac' { return 'audio/aac' }
        '.aif' { return 'audio/aiff' }
        '.aiff' { return 'audio/aiff' }
        '.caf' { return 'audio/x-caf' }
        '.flac' { return 'audio/flac' }
        '.m4a' { return 'audio/mp4' }
        '.mp3' { return 'audio/mpeg' }
        '.ogg' { return 'audio/ogg' }
        '.opus' { return 'audio/ogg' }
        '.wav' { return 'audio/wav' }
        '.webm' { return 'audio/webm' }
        default { throw "Unsupported audio extension '$Extension'." }
    }
}

function Get-AudioProbeMetadata {
    param(
        [Parameter(Mandatory)] [string] $FfprobePath,
        [Parameter(Mandatory)] [string] $AudioPath,
        [Parameter(Mandatory)] [string] $AssetId
    )

    $output = Invoke-CheckedProcess -Executable $FfprobePath -Description "Probing '$AssetId'" -Arguments @(
        '-v', 'error',
        '-show_format',
        '-show_streams',
        '-of', 'json',
        '--', $AudioPath
    )
    try {
        $probe = $output | ConvertFrom-Json
    }
    catch {
        throw "ffprobe returned invalid JSON for '$AssetId': $($_.Exception.Message)"
    }

    $streamsProperty = Get-RequiredProperty -Object $probe -Name 'streams' -Context "ffprobe result for '$AssetId'"
    $streams = @($streamsProperty)
    $audioStreams = @($streams | Where-Object { (Get-OptionalProperty -Object $_ -Name 'codec_type') -eq 'audio' })
    $otherStreams = @($streams | Where-Object { (Get-OptionalProperty -Object $_ -Name 'codec_type') -ne 'audio' })
    if ($audioStreams.Count -ne 1 -or $otherStreams.Count -ne 0) {
        throw "'$AssetId' must contain exactly one audio stream and no video/data streams."
    }

    $audio = $audioStreams[0]
    $codec = [string] (Get-OptionalProperty -Object $audio -Name 'codec_name')
    if ([string]::IsNullOrWhiteSpace($codec)) {
        throw "ffprobe did not report an audio codec for '$AssetId'."
    }
    $sampleRate = Get-PositiveInt -Value (Get-OptionalProperty -Object $audio -Name 'sample_rate')
    if ($null -eq $sampleRate) {
        throw "ffprobe did not report a positive sample rate for '$AssetId'."
    }
    $channels = Get-PositiveInt -Value (Get-OptionalProperty -Object $audio -Name 'channels')
    if ($null -eq $channels) {
        throw "ffprobe did not report a positive channel count for '$AssetId'."
    }

    $format = Get-OptionalProperty -Object $probe -Name 'format'
    $durationSeconds = Get-PositiveDouble -Value (Get-OptionalProperty -Object $format -Name 'duration')
    if ($null -eq $durationSeconds) {
        $durationSeconds = Get-PositiveDouble -Value (Get-OptionalProperty -Object $audio -Name 'duration')
    }
    if ($null -eq $durationSeconds) {
        throw "ffprobe did not report a positive duration for '$AssetId'."
    }

    $metadataJson = [ordered] @{
        formatTags = Get-OptionalProperty -Object $format -Name 'tags'
        streamTags = Get-OptionalProperty -Object $audio -Name 'tags'
    } | ConvertTo-Json -Compress -Depth 8
    Assert-NoForbiddenProvenance -Value $metadataJson -Context "Embedded metadata for '$AssetId'"

    $bitRate = Get-PositiveInt -Value (Get-OptionalProperty -Object $audio -Name 'bit_rate')
    if ($null -eq $bitRate) {
        $bitRate = Get-PositiveInt -Value (Get-OptionalProperty -Object $format -Name 'bit_rate')
    }
    return [pscustomobject] [ordered] @{
        codec = $codec.Trim().ToLowerInvariant()
        sampleRate = [int] $sampleRate
        channels = [int] $channels
        durationMs = [long] [Math]::Max(
            1,
            [Math]::Round($durationSeconds * 1000, [MidpointRounding]::AwayFromZero)
        )
        container = [string] (Get-OptionalProperty -Object $format -Name 'format_name')
        sampleFormat = [string] (Get-OptionalProperty -Object $audio -Name 'sample_fmt')
        bitRate = $bitRate
    }
}

function New-ZipArchive {
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter()] [System.IO.FileInfo[]] $Files
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Refusing to overwrite archive '$ArchivePath'."
    }
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [System.IO.FileStream]::new(
        $ArchivePath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            $script:Utf8NoBom
        )
        try {
            $files = if ($null -eq $Files) {
                @(Get-ChildItem -LiteralPath $SourceDirectory -Force -Recurse -File | Sort-Object FullName)
            }
            else {
                @($Files)
            }
            foreach ($file in $files) {
                $entryName = Get-RelativePath -Root $SourceDirectory -Path $file.FullName
                $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
                $entry.LastWriteTime = $script:FixedZipTimestamp
                $input = $file.OpenRead()
                $output = $entry.Open()
                try {
                    $input.CopyTo($output)
                }
                finally {
                    $output.Dispose()
                    $input.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }
}

function New-AssetPackArchiveParts {
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [string] $DistributionDirectory,
        [Parameter(Mandatory)] [string] $PackVersion,
        [Parameter(Mandatory)] [long] $MaximumPartBytes
    )

    $targetBytes = $MaximumPartBytes - 8388608
    $catalog = Get-Item -LiteralPath (Join-Path $SourceDirectory 'db.json')
    $remaining = @(
        Get-ChildItem -LiteralPath $SourceDirectory -Force -Recurse -File |
            Where-Object { $_.FullName -cne $catalog.FullName } |
            Sort-Object FullName
    )
    $orderedFiles = @($catalog) + $remaining
    $groups = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    [long] $currentBytes = 0
    foreach ($file in $orderedFiles) {
        if ([long] $file.Length -gt $targetBytes) {
            throw "File '$($file.FullName)' is too large for a cacheable archive part."
        }
        if ($current.Count -gt 0 -and ($currentBytes + [long] $file.Length) -gt $targetBytes) {
            $groups.Add($current.ToArray())
            $current = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            $currentBytes = 0
        }
        $current.Add($file)
        $currentBytes += [long] $file.Length
    }
    if ($current.Count -gt 0) {
        $groups.Add($current.ToArray())
    }

    $parts = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $groups.Count; $index++) {
        $ordinal = $index + 1
        $partId = 'part-{0:D3}' -f $ordinal
        $temporary = Join-Path $DistributionDirectory "sound-effects-$PackVersion-$partId.zip.part"
        Write-Host "Creating sound-effects ZIP $ordinal/$($groups.Count)..."
        New-ZipArchive -SourceDirectory $SourceDirectory -ArchivePath $temporary -Files $groups[$index]
        $sha = Get-Sha256 -Path $temporary
        $archiveName = "sound-effects-$PackVersion-$partId-$($sha.Substring(0, 12)).zip"
        $archivePath = Join-Path $DistributionDirectory $archiveName
        [System.IO.File]::Move($temporary, $archivePath)
        $bytes = [long] (Get-Item -LiteralPath $archivePath).Length
        if ($bytes -gt $MaximumPartBytes) {
            throw "Generated part '$archiveName' exceeds the configured cacheable size."
        }
        $parts.Add([ordered] @{
            id = $partId
            url = "./packs/sound-effects/$PackVersion/$archiveName"
            sha256 = $sha
            bytes = $bytes
        })
    }
    return $parts.ToArray()
}

function Assert-NormalizedCatalog {
    param(
        [Parameter(Mandatory)] [string] $PackDirectory,
        [Parameter(Mandatory)] [int] $ExpectedAssetCount
    )

    $catalogPath = Join-Path $PackDirectory 'db.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    if (
        $catalog.schema -cne 'captioncraft-asset-pack' -or
        $catalog.schemaVersion -ne 3 -or
        $catalog.pack.id -cne 'sound-effects' -or
        @($catalog.assets).Count -ne $ExpectedAssetCount
    ) {
        throw 'Generated sound-effects catalog failed its identity/count validation.'
    }
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($asset in @($catalog.assets)) {
        if (-not $ids.Add([string] $asset.id)) {
            throw "Generated catalog contains duplicate asset '$($asset.id)'."
        }
        if ($asset.mediaType -cne 'audio' -or $asset.hasAudio -isnot [bool] -or -not $asset.hasAudio) {
            throw "Generated asset '$($asset.id)' is not valid audio."
        }
        if ([long] $asset.durationMs -le 0) {
            throw "Generated asset '$($asset.id)' has an invalid duration."
        }
        $mediaPath = Resolve-SafeChildPath -Root $PackDirectory -RelativePath ([string] $asset.relativePath)
        if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
            throw "Generated media is missing for '$($asset.id)'."
        }
        if ((Get-Item -LiteralPath $mediaPath).Length -ne [long] $asset.sizeBytes) {
            throw "Generated media size is wrong for '$($asset.id)'."
        }
        foreach ($key in @('mimeType', 'codec', 'sampleRate', 'channels', 'license', 'licenseUrl', 'sourceUrl', 'redistributionCleared')) {
            if ($asset.metadata.PSObject.Properties.Name -notcontains $key) {
                throw "Generated asset '$($asset.id)' is missing metadata.$key."
            }
        }
        if ($asset.metadata.redistributionCleared -isnot [bool] -or -not $asset.metadata.redistributionCleared) {
            throw "Generated asset '$($asset.id)' is not marked redistribution-cleared."
        }
    }
}

function Remove-GeneratedWorkDirectory {
    param(
        [Parameter()] [AllowNull()] [string] $Path,
        [Parameter(Mandatory)] [string[]] $AllowedParents
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }
    $isAllowed = $false
    foreach ($parent in $AllowedParents) {
        if (Test-IsPathWithin -Parent $parent -Candidate $Path) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed -or -not ([System.IO.Path]::GetFileName($Path).Contains(".part-$PID"))) {
        throw "Refusing to clean unexpected generated path '$Path'."
    }
    [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($Path), $true)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stagingParent = Join-Path $repoRoot 'tool\asset_pack_staging\sound-effects'
$distributionParent = Join-Path $repoRoot 'tool\asset_pack_dist\packs\sound-effects'
$sourceDirectory = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path)
$manifestPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ClearanceManifest -ErrorAction Stop).Path)

if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    throw "SourceRoot is not a directory: '$sourceDirectory'."
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "ClearanceManifest is not a file: '$manifestPath'."
}
foreach ($generatedRoot in @($stagingParent, $distributionParent)) {
    if ((Test-IsPathWithin -Parent $sourceDirectory -Candidate $generatedRoot) -or (Test-IsPathWithin -Parent $generatedRoot -Candidate $sourceDirectory)) {
        throw 'SourceRoot must be separate from CaptionCraft generated staging/distribution directories.'
    }
}

Assert-NoReparsePoints -Root $sourceDirectory
$sourceEntries = @(Get-ChildItem -LiteralPath $sourceDirectory -Force -Recurse)
foreach ($entry in $sourceEntries) {
    $relative = Get-RelativePath -Root $sourceDirectory -Path $entry.FullName
    Assert-NoForbiddenProvenance -Value $relative -Context "Source path '$relative'"
}

$manifestRaw = [System.IO.File]::ReadAllText($manifestPath)
Assert-NoForbiddenProvenance -Value $manifestRaw -Context 'Clearance manifest'
try {
    $manifest = $manifestRaw | ConvertFrom-Json
}
catch {
    throw "Clearance manifest is not valid JSON: $($_.Exception.Message)"
}

$schema = Get-RequiredString -Object $manifest -Name 'schema' -Context 'Clearance manifest'
if ($schema -cne 'captioncraft-sfx-clearance-manifest') {
    throw "Clearance manifest has unsupported schema '$schema'."
}
$schemaVersion = Get-RequiredProperty -Object $manifest -Name 'schemaVersion' -Context 'Clearance manifest'
if ($schemaVersion -isnot [long] -and $schemaVersion -isnot [int]) {
    throw 'Clearance manifest schemaVersion must be the JSON integer 1.'
}
if ([long] $schemaVersion -ne 1) {
    throw "Clearance manifest has unsupported schemaVersion '$schemaVersion'."
}

$pack = Get-RequiredProperty -Object $manifest -Name 'pack' -Context 'Clearance manifest'
$packId = Get-RequiredString -Object $pack -Name 'id' -Context 'Clearance manifest pack'
if ($packId -cne 'sound-effects') {
    throw "Clearance manifest pack.id must be 'sound-effects'."
}
$packTitle = Get-RequiredString -Object $pack -Name 'title' -Context 'Clearance manifest pack'

$review = Get-RequiredProperty -Object $manifest -Name 'review' -Context 'Clearance manifest'
Assert-ExactTrue -Object $review -Name 'redistributionRightsConfirmed' -Context 'Clearance manifest review'
$reviewedBy = Get-RequiredString -Object $review -Name 'reviewedBy' -Context 'Clearance manifest review'
$reviewedAtValue = Get-RequiredProperty -Object $review -Name 'reviewedAtUtc' -Context 'Clearance manifest review'
$reviewedAt = [DateTimeOffset]::MinValue
if ($reviewedAtValue -is [DateTime]) {
    if ($reviewedAtValue.Kind -ne [DateTimeKind]::Utc) {
        throw "Clearance manifest review.reviewedAtUtc must be an ISO-8601 UTC timestamp."
    }
    $reviewedAt = [DateTimeOffset]::new($reviewedAtValue)
}
elseif ($reviewedAtValue -is [DateTimeOffset]) {
    $reviewedAt = $reviewedAtValue
}
elseif ($reviewedAtValue -is [string] -and -not [string]::IsNullOrWhiteSpace($reviewedAtValue)) {
    if (-not [DateTimeOffset]::TryParse(
        $reviewedAtValue,
        $script:InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref] $reviewedAt
    )) {
        throw "Clearance manifest review.reviewedAtUtc must be an ISO-8601 UTC timestamp."
    }
}
else {
    throw "Clearance manifest review.reviewedAtUtc must be an ISO-8601 UTC timestamp."
}
if ($reviewedAt.Offset -ne [TimeSpan]::Zero) {
    throw "Clearance manifest review.reviewedAtUtc must be an ISO-8601 UTC timestamp."
}

$assetProperty = Get-RequiredProperty -Object $manifest -Name 'assets' -Context 'Clearance manifest'
if ($assetProperty -is [string] -or $assetProperty -isnot [System.Collections.IEnumerable]) {
    throw 'Clearance manifest assets must be a JSON array.'
}
$manifestAssets = @($assetProperty)
if ($manifestAssets.Count -eq 0) {
    throw 'Clearance manifest must declare at least one sound effect.'
}

$pathComparer = Get-PathComparer
$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$sourcePaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
$categories = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
$descriptors = [System.Collections.Generic.List[object]]::new()

foreach ($item in $manifestAssets) {
    if ($null -eq $item -or $item -isnot [pscustomobject]) {
        throw 'Each clearance manifest asset must be a JSON object.'
    }
    $itemId = Get-RequiredString -Object $item -Name 'id' -Context 'Clearance asset'
    $context = "Clearance asset '$itemId'"
    if ($itemId -cnotmatch $script:StableIdPattern) {
        throw "$context has an unstable id. Use a lowercase kebab-case identifier."
    }
    if (-not $ids.Add($itemId)) {
        throw "Clearance manifest contains duplicate asset id '$itemId'."
    }

    $title = Get-RequiredString -Object $item -Name 'title' -Context $context
    $categoryId = Get-RequiredString -Object $item -Name 'categoryId' -Context $context
    if ($categoryId -cnotmatch $script:StableIdPattern) {
        throw "$context has an invalid categoryId. Use lowercase kebab-case."
    }
    $categoryName = Get-RequiredString -Object $item -Name 'categoryName' -Context $context
    if ($categories.ContainsKey($categoryId)) {
        if ($categories[$categoryId] -cne $categoryName) {
            throw "Category '$categoryId' has conflicting names in the clearance manifest."
        }
    }
    else {
        $categories.Add($categoryId, $categoryName)
    }

    $sourcePathText = Get-RequiredString -Object $item -Name 'sourcePath' -Context $context
    $sourceFile = Resolve-SafeChildPath -Root $sourceDirectory -RelativePath $sourcePathText
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "$context references missing sourcePath '$sourcePathText'."
    }
    $sourceRelativePath = Get-RelativePath -Root $sourceDirectory -Path $sourceFile
    Assert-NoForbiddenProvenance -Value $sourceRelativePath -Context $context
    if (-not $sourcePaths.Add($sourceRelativePath)) {
        throw "Clearance manifest contains duplicate sourcePath '$sourceRelativePath'."
    }
    $extension = [System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant()
    if (-not $script:SupportedAudioExtensions.Contains($extension)) {
        throw "$context uses unsupported audio extension '$extension'."
    }

    $expectedSha256 = Get-RequiredString -Object $item -Name 'expectedSha256' -Context $context
    if ($expectedSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw "$context has an invalid expectedSha256."
    }
    $expectedSha256 = $expectedSha256.ToLowerInvariant()

    $license = Get-RequiredString -Object $item -Name 'license' -Context $context
    if ($license -match '(?i)^(?:unknown|none|n/?a|unlicensed|no[ -]?license)$') {
        throw "$context is unlicensed. A specific redistribution license is required."
    }
    Assert-NoForbiddenProvenance -Value $license -Context $context
    $licenseUrl = Get-RequiredString -Object $item -Name 'licenseUrl' -Context $context
    $sourceUrl = Get-RequiredString -Object $item -Name 'sourceUrl' -Context $context
    Assert-HttpsUrl -Value $licenseUrl -Field 'licenseUrl' -Context $context
    Assert-HttpsUrl -Value $sourceUrl -Field 'sourceUrl' -Context $context
    Assert-NoForbiddenProvenance -Value $licenseUrl -Context $context
    Assert-NoForbiddenProvenance -Value $sourceUrl -Context $context
    Assert-ExactTrue -Object $item -Name 'redistributionCleared' -Context $context

    $creator = Get-OptionalProperty -Object $item -Name 'creator'
    if ($null -ne $creator -and ($creator -isnot [string] -or [string]::IsNullOrWhiteSpace($creator))) {
        throw "$context has an invalid optional creator."
    }
    if ($creator -is [string]) {
        $creator = $creator.Trim()
        Assert-NoForbiddenProvenance -Value $creator -Context $context
    }
    $creatorUrl = Get-OptionalProperty -Object $item -Name 'creatorUrl'
    if ($null -ne $creatorUrl) {
        if ($creatorUrl -isnot [string] -or [string]::IsNullOrWhiteSpace($creatorUrl)) {
            throw "$context has an invalid optional creatorUrl."
        }
        $creatorUrl = $creatorUrl.Trim()
        Assert-HttpsUrl -Value $creatorUrl -Field 'creatorUrl' -Context $context
        Assert-NoForbiddenProvenance -Value $creatorUrl -Context $context
    }
    $attribution = Get-OptionalProperty -Object $item -Name 'attribution'
    if ($null -ne $attribution -and ($attribution -isnot [string] -or [string]::IsNullOrWhiteSpace($attribution))) {
        throw "$context has an invalid optional attribution."
    }
    if ($attribution -is [string]) {
        $attribution = $attribution.Trim()
        Assert-NoForbiddenProvenance -Value $attribution -Context $context
    }

    $tagValues = Get-OptionalProperty -Object $item -Name 'tags'
    if ($null -ne $tagValues -and ($tagValues -is [string] -or $tagValues -isnot [System.Collections.IEnumerable])) {
        throw "$context tags must be a JSON array of strings."
    }
    $tagList = [System.Collections.Generic.List[string]]::new()
    foreach ($tag in @($categoryId) + @($tagValues)) {
        if ($tag -isnot [string] -or [string]::IsNullOrWhiteSpace($tag)) {
            throw "$context contains an invalid tag."
        }
        $normalizedTag = $tag.Trim().ToLowerInvariant()
        if (-not $tagList.Contains($normalizedTag)) {
            $tagList.Add($normalizedTag)
        }
    }

    $descriptors.Add([pscustomobject] [ordered] @{
        id = $itemId
        title = $title
        categoryId = $categoryId
        categoryName = $categoryName
        sourcePath = $sourceRelativePath
        sourceFile = $sourceFile
        extension = $extension
        expectedSha256 = $expectedSha256
        license = $license
        licenseUrl = $licenseUrl
        sourceUrl = $sourceUrl
        creator = $creator
        creatorUrl = $creatorUrl
        attribution = $attribution
        tags = $tagList.ToArray()
        probe = $null
    })
}

$audioFiles = @(
    Get-ChildItem -LiteralPath $sourceDirectory -Force -Recurse -File |
        Where-Object { $script:SupportedAudioExtensions.Contains($_.Extension) }
)
foreach ($audioFile in $audioFiles) {
    $relativePath = Get-RelativePath -Root $sourceDirectory -Path $audioFile.FullName
    if (-not $sourcePaths.Contains($relativePath)) {
        throw "Audio input '$relativePath' is not declared in the clearance manifest and is therefore unlicensed for this release."
    }
}
if ($audioFiles.Count -ne $descriptors.Count) {
    throw 'The clearance manifest does not map one-to-one to source audio files.'
}

Write-Host "Hashing read-only source tree..."
$sourceSnapshotBefore = @(Get-TreeSnapshot -Root $sourceDirectory)
$sourceTreeSha256 = Get-SnapshotDigest -Snapshot $sourceSnapshotBefore
$snapshotByPath = [System.Collections.Generic.Dictionary[string,object]]::new($pathComparer)
foreach ($row in $sourceSnapshotBefore) {
    $snapshotByPath.Add([string] $row.relativePath, $row)
}

$manifestSha256 = Get-Sha256 -Path $manifestPath
$ffprobe = Get-Command ffprobe -ErrorAction Stop
$orderedDescriptors = @($descriptors.ToArray() | Sort-Object id)
$ordinal = 0
foreach ($descriptor in $orderedDescriptors) {
    $ordinal++
    if (-not $snapshotByPath.ContainsKey($descriptor.sourcePath)) {
        throw "Source snapshot is missing '$($descriptor.sourcePath)'."
    }
    $sourceRow = $snapshotByPath[$descriptor.sourcePath]
    if ($sourceRow.sha256 -cne $descriptor.expectedSha256) {
        throw "Clearance hash mismatch for '$($descriptor.id)'. Expected $($descriptor.expectedSha256), found $($sourceRow.sha256)."
    }
    $descriptor.probe = Get-AudioProbeMetadata -FfprobePath $ffprobe.Source -AudioPath $descriptor.sourceFile -AssetId $descriptor.id
    Write-Host ("  [{0}/{1}] validated {2}" -f $ordinal, $orderedDescriptors.Count, $descriptor.id)
}

if ($ValidateOnly) {
    $sourceSnapshotAfter = @(Get-TreeSnapshot -Root $sourceDirectory)
    Assert-SnapshotsEqual -Expected $sourceSnapshotBefore -Actual $sourceSnapshotAfter
    $totalBytes = [long] (($audioFiles | Measure-Object Length -Sum).Sum)
    $totalDurationMs = [long] (($orderedDescriptors | ForEach-Object { $_.probe.durationMs } | Measure-Object -Sum).Sum)
    Write-Host ''
    Write-Host ("Validation passed: assets={0}, bytes={1}, durationMs={2}" -f $orderedDescriptors.Count, $totalBytes, $totalDurationMs)
    Write-Host "Source tree remained unchanged: $sourceTreeSha256"
    Write-Host 'ValidateOnly created no staging files, ZIP, or release metadata.'
    return
}

$stagingFinal = Join-Path $stagingParent $Version
$distributionFinal = Join-Path $distributionParent $Version
foreach ($target in @($stagingFinal, $distributionFinal)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite immutable generated target '$target'. Choose a new version."
    }
}

$stagingWork = Join-Path $stagingParent ".$Version.part-$PID"
$distributionWork = Join-Path $distributionParent ".$Version.part-$PID"
$stagingMoved = $false
$distributionMoved = $false
try {
    foreach ($workPath in @($stagingWork, $distributionWork)) {
        if (Test-Path -LiteralPath $workPath) {
            throw "Refusing to overwrite generated work directory '$workPath'."
        }
        [void] [System.IO.Directory]::CreateDirectory($workPath)
    }

    $catalogAssets = [System.Collections.Generic.List[object]]::new()
    foreach ($descriptor in $orderedDescriptors) {
        $relativePath = "sounds/$($descriptor.categoryId)/$($descriptor.id)$($descriptor.extension)"
        $destination = Resolve-SafeChildPath -Root $stagingWork -RelativePath $relativePath
        [void] [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
        [System.IO.File]::Copy($descriptor.sourceFile, $destination, $false)
        $copiedSha256 = Get-Sha256 -Path $destination
        if ($copiedSha256 -cne $descriptor.expectedSha256) {
            throw "Staging copy verification failed for '$($descriptor.id)'."
        }
        $file = Get-Item -LiteralPath $destination

        $provenance = [ordered] @{
            sourceSha256 = $descriptor.expectedSha256
            clearanceManifestSha256 = $manifestSha256
            reviewedBy = $reviewedBy
            reviewedAtUtc = $reviewedAt.ToUniversalTime().ToString('o', $script:InvariantCulture)
        }
        if ($null -ne $descriptor.creator) {
            $provenance.creator = $descriptor.creator
        }
        if ($null -ne $descriptor.creatorUrl) {
            $provenance.creatorUrl = $descriptor.creatorUrl
        }
        if ($null -ne $descriptor.attribution) {
            $provenance.attribution = $descriptor.attribution
        }

        $metadata = [ordered] @{
            mimeType = Get-AudioMimeType -Extension $descriptor.extension
            container = $descriptor.probe.container
            codec = $descriptor.probe.codec
            sampleRate = $descriptor.probe.sampleRate
            channels = $descriptor.probe.channels
            license = $descriptor.license
            licenseUrl = $descriptor.licenseUrl
            sourceUrl = $descriptor.sourceUrl
            redistributionCleared = $true
            provenance = $provenance
        }
        if (-not [string]::IsNullOrWhiteSpace($descriptor.probe.sampleFormat)) {
            $metadata.sampleFormat = $descriptor.probe.sampleFormat
        }
        if ($null -ne $descriptor.probe.bitRate) {
            $metadata.bitRate = $descriptor.probe.bitRate
        }
        if ($null -ne $descriptor.creator) {
            $metadata.creatorName = $descriptor.creator
        }
        if ($null -ne $descriptor.creatorUrl) {
            $metadata.creatorPageUrl = $descriptor.creatorUrl
        }
        if ($null -ne $descriptor.attribution) {
            $metadata.attribution = $descriptor.attribution
        }

        $catalogAssets.Add([ordered] @{
            id = $descriptor.id
            title = $descriptor.title
            categoryId = $descriptor.categoryId
            mediaType = 'audio'
            relativePath = $relativePath
            sizeBytes = [long] $file.Length
            durationMs = [long] $descriptor.probe.durationMs
            hasAudio = $true
            tags = @($descriptor.tags)
            metadata = $metadata
        })
    }

    $catalogCategories = [System.Collections.Generic.List[object]]::new()
    foreach ($categoryId in @($categories.Keys | Sort-Object)) {
        $catalogCategories.Add([ordered] @{
            id = $categoryId
            name = $categories[$categoryId]
        })
    }
    $catalog = [ordered] @{
        schema = 'captioncraft-asset-pack'
        schemaVersion = 3
        pack = [ordered] @{
            id = 'sound-effects'
            title = $packTitle
            version = $Version
        }
        categories = $catalogCategories.ToArray()
        assets = $catalogAssets.ToArray()
    }
    Write-JsonFile -Path (Join-Path $stagingWork 'db.json') -Value $catalog
    Assert-NormalizedCatalog -PackDirectory $stagingWork -ExpectedAssetCount $orderedDescriptors.Count

    $installedFiles = @(Get-ChildItem -LiteralPath $stagingWork -Force -Recurse -File)
    $installedBytes = [long] (($installedFiles | Measure-Object Length -Sum).Sum)
    $archiveParts = @(New-AssetPackArchiveParts `
        -SourceDirectory $stagingWork `
        -DistributionDirectory $distributionWork `
        -PackVersion $Version `
        -MaximumPartBytes $MaxPartBytes)
    [long] $archiveBytes = 0
    foreach ($archivePart in $archiveParts) {
        $archiveBytes += [long] $archivePart.bytes
    }
    $totalDurationMs = [long] (($orderedDescriptors | ForEach-Object { $_.probe.durationMs } | Measure-Object -Sum).Sum)

    $release = [ordered] @{
        schema = 'captioncraft-asset-pack-release'
        schemaVersion = 2
        pack = [ordered] @{
            id = 'sound-effects'
            version = $Version
            title = $packTitle
            description = 'Rights-cleared sound effects for offline use in CaptionCraft.'
            assetCount = $orderedDescriptors.Count
            installedBytes = $installedBytes
            catalogPath = 'db.json'
            catalogSchemaVersion = 3
            minAppBuild = 2005
            parts = $archiveParts
        }
        audit = [ordered] @{
            assets = $orderedDescriptors.Count
            durationMs = $totalDurationMs
            sourceTreeSha256 = $sourceTreeSha256
            clearanceManifestSha256 = $manifestSha256
            sourceReadOnlyVerification = 'sha256-size-path-and-last-write-time'
            redistributionRightsConfirmed = $true
        }
    }
    $releaseFingerprintInput = ($archiveParts | ConvertTo-Json -Compress -Depth 8)
    $releaseFingerprintBytes = $script:Utf8NoBom.GetBytes($releaseFingerprintInput)
    $releaseFingerprint = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($releaseFingerprintBytes)
    ).ToLowerInvariant()
    $releaseName = "sound-effects-$Version-$($releaseFingerprint.Substring(0, 12)).release.json"
    Write-JsonFile -Path (Join-Path $distributionWork $releaseName) -Value $release

    Write-Host 'Re-hashing original source tree to prove it was not changed...'
    $sourceSnapshotAfter = @(Get-TreeSnapshot -Root $sourceDirectory)
    Assert-SnapshotsEqual -Expected $sourceSnapshotBefore -Actual $sourceSnapshotAfter

    [void] [System.IO.Directory]::CreateDirectory($distributionParent)
    [System.IO.Directory]::Move($distributionWork, $distributionFinal)
    $distributionMoved = $true
    [void] [System.IO.Directory]::CreateDirectory($stagingParent)
    [System.IO.Directory]::Move($stagingWork, $stagingFinal)
    $stagingMoved = $true

    Write-Host ''
    Write-Host "Prepared staging catalog: $(Join-Path $stagingFinal 'db.json')"
    Write-Host "Prepared $($archiveParts.Count) immutable archive part(s) in: $distributionFinal"
    Write-Host "Prepared release metadata: $(Join-Path $distributionFinal $releaseName)"
    Write-Host ("assets={0}, parts={1}, archiveBytes={2}, installedBytes={3}" -f $orderedDescriptors.Count, $archiveParts.Count, $archiveBytes, $installedBytes)
    Write-Host "Verified that the original source tree remained unchanged: $sourceTreeSha256"
}
catch {
    foreach ($workPath in @($stagingWork, $distributionWork)) {
        Remove-GeneratedWorkDirectory -Path $workPath -AllowedParents @($stagingParent, $distributionParent)
    }
    if ($stagingMoved -and (Test-Path -LiteralPath $stagingFinal)) {
        [System.IO.Directory]::Delete($stagingFinal, $true)
    }
    if ($distributionMoved -and (Test-Path -LiteralPath $distributionFinal)) {
        [System.IO.Directory]::Delete($distributionFinal, $true)
    }
    throw
}
