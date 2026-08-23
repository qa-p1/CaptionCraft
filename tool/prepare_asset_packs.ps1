[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot = 'D:\Aadi\Editing assests',

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '1.0.0',

    # Leave headroom below Cloudflare's 512 MiB cacheable-object ceiling.
    [Parameter()]
    [ValidateRange(1048576, 503316480)]
    [long] $MaxPartBytes = 471859200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:FixedZipTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value,
        [Parameter()] [int] $Depth = 12
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, "$json`n", $script:Utf8NoBom)
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Resolve-SafeChildPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $portable = $RelativePath.Trim().Replace('\', '/')
    if (
        [string]::IsNullOrWhiteSpace($portable) -or
        $portable.StartsWith('/') -or
        $portable.Contains(':') -or
        $portable.Split('/').Contains('..')
    ) {
        throw "Unsafe relative path: $RelativePath"
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $nativeRelative = $portable.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $nativeRelative))
    $prefix = "$rootFull$([System.IO.Path]::DirectorySeparatorChar)"
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its root: $RelativePath"
    }
    return $resolved
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)

    $files = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -File | Sort-Object FullName)
    $rows = @(
        foreach ($file in $files) {
            [pscustomobject] [ordered] @{
                relativePath       = Get-RelativePath -Root $Root -Path $file.FullName
                sizeBytes          = [long] $file.Length
                lastWriteUtcTicks  = [long] $file.LastWriteTimeUtc.Ticks
                sha256             = Get-Sha256 -Path $file.FullName
            }
        }
    )
    return ,$rows
}

function Get-SnapshotDigest {
    param([Parameter(Mandatory)] [object[]] $Snapshot)

    $lines = foreach ($row in $Snapshot) {
        "$($row.relativePath)`t$($row.sizeBytes)`t$($row.sha256)`n"
    }
    $bytes = $script:Utf8NoBom.GetBytes(($lines -join ''))
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Assert-SnapshotsEqual {
    param(
        [Parameter(Mandatory)] [object[]] $Expected,
        [Parameter(Mandatory)] [object[]] $Actual,
        [Parameter(Mandatory)] [string] $Description,
        [switch] $IncludeTimestamps
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Description file count changed: expected $($Expected.Count), found $($Actual.Count)."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $left = $Expected[$index]
        $right = $Actual[$index]
        if (
            $left.relativePath -cne $right.relativePath -or
            $left.sizeBytes -ne $right.sizeBytes -or
            $left.sha256 -cne $right.sha256 -or
            ($IncludeTimestamps -and $left.lastWriteUtcTicks -ne $right.lastWriteUtcTicks)
        ) {
            throw "$Description changed at '$($left.relativePath)'."
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
            throw "Could not start $Executable."
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

function Get-MediaProbe {
    param(
        [Parameter(Mandatory)] [string] $FfprobePath,
        [Parameter(Mandatory)] [string] $MediaPath
    )

    $output = Invoke-CheckedProcess -Executable $FfprobePath -Description "Probing '$MediaPath'" -Arguments @(
        '-v', 'error',
        '-show_format',
        '-show_streams',
        '-of', 'json',
        '--', $MediaPath
    )
    try {
        return $output | ConvertFrom-Json
    }
    catch {
        throw "ffprobe returned invalid JSON for '$MediaPath': $($_.Exception.Message)"
    }
}

function Get-PositiveDouble {
    param([Parameter()] [object] $Value)

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

function Get-FrameRate {
    param([Parameter()] [object] $VideoStream)

    if ($null -eq $VideoStream) {
        return $null
    }
    foreach ($field in @('avg_frame_rate', 'r_frame_rate')) {
        $value = $VideoStream.$field
        if ($null -eq $value) {
            continue
        }
        $parts = ([string] $value).Split('/')
        if ($parts.Count -eq 2) {
            $numerator = Get-PositiveDouble -Value $parts[0]
            $denominator = Get-PositiveDouble -Value $parts[1]
            if ($null -ne $numerator -and $null -ne $denominator) {
                return [Math]::Round($numerator / $denominator, 3)
            }
        }
        else {
            $parsed = Get-PositiveDouble -Value $value
            if ($null -ne $parsed) {
                return [Math]::Round($parsed, 3)
            }
        }
    }
    return $null
}

function Get-DurationMilliseconds {
    param(
        [Parameter(Mandatory)] [object] $Probe,
        [Parameter()] [object] $VideoStream
    )

    $seconds = Get-PositiveDouble -Value $Probe.format.duration
    if ($null -eq $seconds -and $null -ne $VideoStream) {
        $seconds = Get-PositiveDouble -Value $VideoStream.duration
    }
    if ($null -eq $seconds) {
        return $null
    }
    return [long] [Math]::Max(1, [Math]::Round($seconds * 1000, [MidpointRounding]::AwayFromZero))
}

function Convert-ToTitle {
    param([Parameter(Mandatory)] [string] $FileStem)

    $description = $FileStem -replace '^[^_]+_[0-9]{3}_', ''
    $description = ($description -replace '[-_]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($description)) {
        return $FileStem
    }
    return $script:InvariantCulture.TextInfo.ToTitleCase($description)
}

function Get-AssetTags {
    param(
        [Parameter(Mandatory)] [string] $PackKind,
        [Parameter(Mandatory)] [string] $CategoryId,
        [Parameter(Mandatory)] [string] $FileStem
    )

    $tags = [System.Collections.Generic.List[string]]::new()
    $stemParts = $FileStem.Split(
        [char[]] @('-', '_'),
        [System.StringSplitOptions]::RemoveEmptyEntries
    )
    foreach ($candidate in @($PackKind) + $CategoryId.Split('-') + $stemParts) {
        $tag = $candidate.Trim().ToLowerInvariant()
        if ($tag.Length -ge 2 -and -not $tags.Contains($tag)) {
            $tags.Add($tag)
        }
    }
    # Let PowerShell enumerate the strings here. The caller wraps the pipeline
    # result once, producing JSON `tags: ["..."]` instead of `tags: [["..."]]`.
    return $tags.ToArray()
}

function Get-OverlayCompositingMetadata {
    param(
        [Parameter(Mandatory)] [string] $FileStem,
        [Parameter(Mandatory)] [string] $MediaType
    )

    if ($FileStem -match '(?:^|-)green-screen(?:-|$)') {
        return [ordered] @{
            mode = 'chromaKey'
            chromaKey = [ordered] @{
                enabled = $true
                color = '#00FF00'
                similarity = 0.35
                blend = 0.10
            }
        }
    }
    if ($MediaType -eq 'image') {
        return [ordered] @{ mode = 'normal'; opacity = 1.0 }
    }
    # CaptionCraft currently implements keyed overlays, not a screen blend.
    # Encode the behavior explicitly instead of labeling black-key footage as
    # `screen`, which made the catalog contract misleading.
    return [ordered] @{
        mode = 'chromaKey'
        chromaKey = [ordered] @{
            enabled = $true
            color = '#000000'
            similarity = 0.22
            blend = 0.08
        }
    }
}

function New-MediaPreview {
    param(
        [Parameter(Mandatory)] [string] $FfmpegPath,
        [Parameter(Mandatory)] [string] $MediaPath,
        [Parameter(Mandatory)] [string] $PreviewPath,
        [Parameter(Mandatory)] [string] $MediaType,
        [Parameter()] [long] $DurationMs = 0
    )

    if (Test-Path -LiteralPath $PreviewPath) {
        throw "Refusing to overwrite preview '$PreviewPath'."
    }
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', $MediaPath)) {
        $arguments.Add($argument)
    }
    if ($MediaType -eq 'video' -and $DurationMs -gt 0) {
        $seekSeconds = [Math]::Min(3.0, ($DurationMs / 1000.0) * 0.2)
        if ($seekSeconds -gt 0.04) {
            $arguments.Add('-ss')
            $arguments.Add($seekSeconds.ToString('0.###', $script:InvariantCulture))
        }
    }
    foreach ($argument in @(
        '-vf', 'scale=480:480:force_original_aspect_ratio=decrease',
        '-frames:v', '1',
        '-q:v', '3',
        $PreviewPath
    )) {
        $arguments.Add($argument)
    }
    [void] (Invoke-CheckedProcess -Executable $FfmpegPath -Arguments $arguments.ToArray() -Description "Generating preview for '$MediaPath'")
    $preview = Get-Item -LiteralPath $PreviewPath
    if ($preview.Length -le 0) {
        throw "Generated preview is empty: '$PreviewPath'."
    }
}

function Convert-AviToMp4 {
    param(
        [Parameter(Mandatory)] [string] $FfmpegPath,
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        throw "Refusing to overwrite transcoded media '$OutputPath'."
    }
    [void] (Invoke-CheckedProcess -Executable $FfmpegPath -Description "Transcoding '$InputPath'" -Arguments @(
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', $InputPath,
        '-map', '0:v:0',
        '-map', '0:a?',
        '-c:v', 'libx264',
        '-preset', 'medium',
        '-crf', '20',
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-c:a', 'aac',
        '-b:a', '192k',
        $OutputPath
    ))
    $output = Get-Item -LiteralPath $OutputPath
    if ($output.Length -le 0) {
        throw "Transcoded media is empty: '$OutputPath'."
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
        [Parameter(Mandatory)] [string] $PackId,
        [Parameter(Mandatory)] [string] $PackVersion,
        [Parameter(Mandatory)] [long] $MaximumPartBytes
    )

    # ZIP metadata adds a small amount of overhead. Target 8 MiB below the
    # hard limit and validate the finished object as a second line of defense.
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
    if ($groups.Count -eq 0) {
        throw "Pack '$PackId' contains no files."
    }

    $parts = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $groups.Count; $index++) {
        $ordinal = $index + 1
        $partId = 'part-{0:D3}' -f $ordinal
        $temporary = Join-Path $DistributionDirectory "$PackId-$PackVersion-$partId.zip.part"
        Write-Host "Creating ZIP $ordinal/$($groups.Count) for $PackId..."
        New-ZipArchive -SourceDirectory $SourceDirectory -ArchivePath $temporary -Files $groups[$index]
        $sha = Get-Sha256 -Path $temporary
        $archiveName = "$PackId-$PackVersion-$partId-$($sha.Substring(0, 12)).zip"
        $archivePath = Join-Path $DistributionDirectory $archiveName
        [System.IO.File]::Move($temporary, $archivePath)
        $bytes = [long] (Get-Item -LiteralPath $archivePath).Length
        if ($bytes -gt $MaximumPartBytes) {
            throw "Generated part '$archiveName' exceeds the configured cacheable size."
        }
        $parts.Add([ordered] @{
            id = $partId
            url = "./packs/$PackId/$PackVersion/$archiveName"
            sha256 = $sha
            bytes = $bytes
        })
    }
    return $parts.ToArray()
}

function Assert-SourceCatalog {
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [object] $Definition
    )

    $dbPath = Join-Path $SourceDirectory 'db.json'
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        throw "Missing source catalog '$dbPath'."
    }
    $catalog = Get-Content -LiteralPath $dbPath -Raw | ConvertFrom-Json
    if ($catalog.schema -ne 'asset-library' -or $catalog.schemaVersion -ne 2) {
        throw "Source catalog '$dbPath' does not use asset-library schema version 2."
    }
    if ($catalog.library -ne $Definition.SourceLibrary) {
        throw "Source catalog '$dbPath' identifies the wrong library."
    }

    $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void] $declared.Add('db.json')
    $assetCount = 0
    foreach ($category in @($catalog.categories)) {
        if ([string]::IsNullOrWhiteSpace([string] $category.id) -or [string]::IsNullOrWhiteSpace([string] $category.name)) {
            throw "Source catalog '$dbPath' has an invalid category."
        }
        foreach ($media in @($category.files)) {
            $relativePath = ([string] $media.path).Replace('\', '/')
            $mediaPath = Resolve-SafeChildPath -Root $SourceDirectory -RelativePath $relativePath
            if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
                throw "Source catalog references missing media '$relativePath'."
            }
            $file = Get-Item -LiteralPath $mediaPath
            if ([long] $media.sizeBytes -ne [long] $file.Length) {
                throw "Source catalog size is stale for '$relativePath'."
            }
            if (-not $declared.Add($relativePath)) {
                throw "Source catalog contains duplicate path '$relativePath'."
            }
            $assetCount++
        }
    }
    $onDisk = @(
        Get-ChildItem -LiteralPath $SourceDirectory -Force -Recurse -File |
            ForEach-Object { Get-RelativePath -Root $SourceDirectory -Path $_.FullName }
    )
    foreach ($relativePath in $onDisk) {
        if (-not $declared.Contains($relativePath)) {
            throw "Uncatalogued source file '$relativePath' would make the pack ambiguous."
        }
    }
    if ($onDisk.Count -ne $declared.Count) {
        throw "Source catalog '$dbPath' does not match its directory tree."
    }
    return [pscustomobject] @{
        catalog = $catalog
        assetCount = $assetCount
    }
}

function Assert-NormalizedCatalog {
    param(
        [Parameter(Mandatory)] [string] $PackDirectory,
        [Parameter(Mandatory)] [string] $ExpectedPackId,
        [Parameter(Mandatory)] [int] $ExpectedAssetCount
    )

    $dbPath = Join-Path $PackDirectory 'db.json'
    $catalog = Get-Content -LiteralPath $dbPath -Raw | ConvertFrom-Json
    if (
        $catalog.schema -ne 'captioncraft-asset-pack' -or
        $catalog.schemaVersion -ne 3 -or
        $catalog.pack.id -ne $ExpectedPackId -or
        @($catalog.assets).Count -ne $ExpectedAssetCount
    ) {
        throw "Normalized catalog validation failed for '$ExpectedPackId'."
    }
    $categoryIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($category in @($catalog.categories)) {
        if (-not $categoryIds.Add([string] $category.id)) {
            throw "Duplicate category '$($category.id)' in '$ExpectedPackId'."
        }
    }
    $assetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($asset in @($catalog.assets)) {
        foreach ($required in @('id', 'title', 'categoryId', 'mediaType', 'relativePath', 'previewPath', 'sizeBytes', 'hasAudio', 'tags', 'metadata')) {
            if ($asset.PSObject.Properties.Name -notcontains $required) {
                throw "Asset '$($asset.id)' is missing '$required'."
            }
        }
        if (-not $assetIds.Add([string] $asset.id)) {
            throw "Duplicate asset '$($asset.id)' in '$ExpectedPackId'."
        }
        if (-not $categoryIds.Contains([string] $asset.categoryId)) {
            throw "Asset '$($asset.id)' has an unknown category."
        }
        $mediaPath = Resolve-SafeChildPath -Root $PackDirectory -RelativePath ([string] $asset.relativePath)
        $previewPath = Resolve-SafeChildPath -Root $PackDirectory -RelativePath ([string] $asset.previewPath)
        if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
            throw "Normalized media is missing for '$($asset.id)'."
        }
        if ((Get-Item -LiteralPath $mediaPath).Length -ne [long] $asset.sizeBytes) {
            throw "Normalized media size is wrong for '$($asset.id)'."
        }
        if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) {
            throw "Normalized preview is missing for '$($asset.id)'."
        }
        if ($asset.mediaType -eq 'video' -and ([long] $asset.durationMs -le 0)) {
            throw "Video duration is invalid for '$($asset.id)'."
        }
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stagingRoot = Join-Path $repoRoot 'tool\asset_pack_staging'
$distRoot = Join-Path $repoRoot 'tool\asset_pack_dist'

foreach ($target in @($stagingRoot, $distRoot)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to continue because generated target already exists: '$target'. Move or remove it deliberately before preparing a new release."
    }
}

$ffmpeg = Get-Command ffmpeg -ErrorAction Stop
$ffprobe = Get-Command ffprobe -ErrorAction Stop
$packDefinitions = @(
    [pscustomobject] [ordered] @{
        Id = 'background-videos'
        Title = 'Background Videos'
        Kind = 'background'
        SourceFolder = 'background'
        SourceLibrary = 'background'
    },
    [pscustomobject] [ordered] @{
        Id = 'overlays'
        Title = 'Overlays'
        Kind = 'overlay'
        SourceFolder = 'Overlays'
        SourceLibrary = 'overlays'
    }
)

$sourceState = @{}
Write-Host 'Preflighting and hashing read-only source libraries...'
foreach ($definition in $packDefinitions) {
    $sourceDirectory = Join-Path $SourceRoot $definition.SourceFolder
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Source library does not exist: '$sourceDirectory'."
    }
    $reparsePoints = @(Get-ChildItem -LiteralPath $sourceDirectory -Force -Recurse | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
    if ($reparsePoints.Count -gt 0) {
        throw "Source library contains a link/reparse point: '$($reparsePoints[0].FullName)'."
    }
    $validated = Assert-SourceCatalog -SourceDirectory $sourceDirectory -Definition $definition
    $snapshot = Get-TreeSnapshot -Root $sourceDirectory
    $sourceState[$definition.Id] = [pscustomobject] @{
        directory = $sourceDirectory
        catalog = $validated.catalog
        assetCount = $validated.assetCount
        snapshot = $snapshot
        digest = Get-SnapshotDigest -Snapshot $snapshot
        bytes = [long] (($snapshot | Measure-Object sizeBytes -Sum).Sum)
    }
}

[void] (New-Item -ItemType Directory -Path $stagingRoot)
[void] (New-Item -ItemType Directory -Path $distRoot)

Write-Host 'Copying exact source trees into ignored staging...'
foreach ($definition in $packDefinitions) {
    $state = $sourceState[$definition.Id]
    $packDirectory = Join-Path $stagingRoot $definition.Id
    [void] (New-Item -ItemType Directory -Path $packDirectory)
    foreach ($item in @(Get-ChildItem -LiteralPath $state.directory -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $packDirectory -Recurse
    }
    $copiedSnapshot = Get-TreeSnapshot -Root $packDirectory
    Assert-SnapshotsEqual -Expected $state.snapshot -Actual $copiedSnapshot -Description "Initial staging copy for '$($definition.Id)'"
}

$releaseRows = [System.Collections.Generic.List[object]]::new()
$reportRows = [System.Collections.Generic.List[object]]::new()
$aviTranscodes = 0
$finalMediaProbes = 0
$transcodeInputProbes = 0

foreach ($definition in $packDefinitions) {
    $state = $sourceState[$definition.Id]
    $packDirectory = Join-Path $stagingRoot $definition.Id
    $previewDirectory = Join-Path $packDirectory '_previews'
    [void] (New-Item -ItemType Directory -Path $previewDirectory)

    $normalizedCategories = [System.Collections.Generic.List[object]]::new()
    $normalizedAssets = [System.Collections.Generic.List[object]]::new()
    $assetOrdinal = 0
    Write-Host "Normalizing $($definition.Title) ($($state.assetCount) assets)..."
    foreach ($category in @($state.catalog.categories)) {
        $normalizedCategories.Add([ordered] @{
            id = [string] $category.id
            name = [string] $category.name
        })
        foreach ($sourceMedia in @($category.files)) {
            $assetOrdinal++
            $originalRelativePath = ([string] $sourceMedia.path).Replace('\', '/')
            $relativePath = $originalRelativePath
            $mediaPath = Resolve-SafeChildPath -Root $packDirectory -RelativePath $relativePath
            $sourceExtension = [System.IO.Path]::GetExtension($mediaPath).ToLowerInvariant()
            $transcodedFrom = $null

            if ($sourceExtension -eq '.avi') {
                if ($definition.Id -ne 'overlays') {
                    throw "The guarded AVI outlier appeared in an unexpected pack."
                }
                [void] (Get-MediaProbe -FfprobePath $ffprobe.Source -MediaPath $mediaPath)
                $transcodeInputProbes++
                $relativePath = [System.IO.Path]::ChangeExtension($relativePath, '.mp4').Replace('\', '/')
                $mp4Path = Resolve-SafeChildPath -Root $packDirectory -RelativePath $relativePath
                Convert-AviToMp4 -FfmpegPath $ffmpeg.Source -InputPath $mediaPath -OutputPath $mp4Path
                # This AVI is a copy created under this run's new staging root. The read-only source is never changed.
                [System.IO.File]::Delete($mediaPath)
                $mediaPath = $mp4Path
                $transcodedFrom = 'avi'
                $aviTranscodes++
            }

            $probe = Get-MediaProbe -FfprobePath $ffprobe.Source -MediaPath $mediaPath
            $finalMediaProbes++
            $videoStreams = @($probe.streams | Where-Object { $_.codec_type -eq 'video' })
            $audioStreams = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' })
            if ($videoStreams.Count -lt 1) {
                throw "Media has no video/image stream: '$mediaPath'."
            }
            $videoStream = $videoStreams[0]
            $mediaType = if ([string] $sourceMedia.kind -eq 'image') { 'image' } else { 'video' }
            $durationMs = if ($mediaType -eq 'video') { Get-DurationMilliseconds -Probe $probe -VideoStream $videoStream } else { $null }
            if ($mediaType -eq 'video' -and $null -eq $durationMs) {
                throw "Could not determine video duration for '$mediaPath'."
            }
            $width = [int] $videoStream.width
            $height = [int] $videoStream.height
            if ($width -le 0 -or $height -le 0) {
                throw "Could not determine dimensions for '$mediaPath'."
            }

            $assetId = [System.IO.Path]::GetFileNameWithoutExtension($originalRelativePath).ToLowerInvariant()
            if ($assetId -notmatch '^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:_[0-9]{3}_[a-z0-9-]+)?$') {
                throw "Generated asset id is not portable: '$assetId'."
            }
            $previewRelativePath = "_previews/$assetId.jpg"
            $previewPath = Resolve-SafeChildPath -Root $packDirectory -RelativePath $previewRelativePath
            New-MediaPreview -FfmpegPath $ffmpeg.Source -MediaPath $mediaPath -PreviewPath $previewPath -MediaType $mediaType -DurationMs ([long] ($durationMs ?? 0))

            $frameRate = Get-FrameRate -VideoStream $videoStream
            $metadata = [ordered] @{
                role = $definition.Kind
                container = [System.IO.Path]::GetExtension($mediaPath).TrimStart('.').ToLowerInvariant()
                videoCodec = [string] $videoStream.codec_name
                pixelFormat = [string] $videoStream.pix_fmt
                frameRate = $frameRate
                defaultPlacement = [ordered] @{
                    fitMode = if ($definition.Kind -eq 'background') { 'cover' } else { 'contain' }
                    alignment = 'center'
                    scale = 1.0
                    muted = $true
                }
                compositing = if ($definition.Kind -eq 'background') {
                    [ordered] @{ mode = 'normal'; opacity = 1.0 }
                }
                else {
                    Get-OverlayCompositingMetadata -FileStem $assetId -MediaType $mediaType
                }
            }
            if ($null -ne $transcodedFrom) {
                $metadata.transcodedFrom = $transcodedFrom
                $metadata.transcodeProfile = 'h264-yuv420p-crf20'
            }

            $file = Get-Item -LiteralPath $mediaPath
            $normalizedAssets.Add([ordered] @{
                id = $assetId
                title = Convert-ToTitle -FileStem $assetId
                categoryId = [string] $category.id
                mediaType = $mediaType
                relativePath = $relativePath
                previewPath = $previewRelativePath
                sizeBytes = [long] $file.Length
                width = $width
                height = $height
                durationMs = $durationMs
                hasAudio = ($audioStreams.Count -gt 0)
                tags = @(Get-AssetTags -PackKind $definition.Kind -CategoryId ([string] $category.id) -FileStem $assetId)
                metadata = $metadata
            })
            Write-Host ("  [{0}/{1}] {2}" -f $assetOrdinal, $state.assetCount, $relativePath)
        }
    }

    $normalizedCatalog = [ordered] @{
        schema = 'captioncraft-asset-pack'
        schemaVersion = 3
        pack = [ordered] @{
            id = $definition.Id
            title = $definition.Title
            version = $Version
        }
        categories = $normalizedCategories.ToArray()
        assets = $normalizedAssets.ToArray()
    }
    Write-JsonFile -Path (Join-Path $packDirectory 'db.json') -Value $normalizedCatalog
    Assert-NormalizedCatalog -PackDirectory $packDirectory -ExpectedPackId $definition.Id -ExpectedAssetCount $state.assetCount

    $installedFiles = @(Get-ChildItem -LiteralPath $packDirectory -Force -Recurse -File)
    $installedBytes = [long] (($installedFiles | Measure-Object Length -Sum).Sum)
    $imageCount = @($normalizedAssets | Where-Object { $_.mediaType -eq 'image' }).Count
    $videoCount = @($normalizedAssets | Where-Object { $_.mediaType -eq 'video' }).Count

    $packDistDirectory = Join-Path $distRoot "packs\$($definition.Id)\$Version"
    [void] (New-Item -ItemType Directory -Path $packDistDirectory)
    $archiveParts = @(New-AssetPackArchiveParts `
        -SourceDirectory $packDirectory `
        -DistributionDirectory $packDistDirectory `
        -PackId $definition.Id `
        -PackVersion $Version `
        -MaximumPartBytes $MaxPartBytes)
    [long] $archiveBytes = 0
    foreach ($archivePart in $archiveParts) {
        $archiveBytes += [long] $archivePart.bytes
    }

    $releaseRows.Add([ordered] @{
        id = $definition.Id
        version = $Version
        title = $definition.Title
        description = if ($definition.Id -eq 'background-videos') {
            'Curated motion backgrounds for CaptionCraft projects.'
        }
        else {
            'Curated image and video overlays for CaptionCraft projects.'
        }
        assetCount = $state.assetCount
        installedBytes = $installedBytes
        catalogPath = 'db.json'
        catalogSchemaVersion = 3
        minAppBuild = 2005
        parts = $archiveParts
    })
    $reportRows.Add([ordered] @{
        id = $definition.Id
        title = $definition.Title
        version = $Version
        sourceDirectory = $state.directory
        sourceFiles = $state.snapshot.Count
        sourceBytes = $state.bytes
        sourceTreeSha256Before = $state.digest
        sourceTreeSha256After = $null
        sourceContentUnchanged = $false
        sourceMetadataUnchanged = $false
        assets = $state.assetCount
        images = $imageCount
        videos = $videoCount
        previews = $state.assetCount
        installedFiles = $installedFiles.Count
        installedBytes = $installedBytes
        archiveParts = $archiveParts
        archiveBytes = $archiveBytes
    })
}

if ($aviTranscodes -ne 1 -or $transcodeInputProbes -ne 1) {
    throw "Expected exactly one guarded staging AVI transcode, completed $aviTranscodes."
}
if ($finalMediaProbes -ne (($sourceState['background-videos'].assetCount) + ($sourceState['overlays'].assetCount))) {
    throw "Not every final media item was probed."
}

Write-Host 'Re-hashing original source trees to prove they were not changed...'
foreach ($report in $reportRows) {
    $state = $sourceState[$report.id]
    $afterSnapshot = Get-TreeSnapshot -Root $state.directory
    Assert-SnapshotsEqual -Expected $state.snapshot -Actual $afterSnapshot -Description "Read-only source '$($report.id)'" -IncludeTimestamps
    $afterDigest = Get-SnapshotDigest -Snapshot $afterSnapshot
    $report.sourceTreeSha256After = $afterDigest
    $report.sourceContentUnchanged = ($afterDigest -eq $state.digest)
    $report.sourceMetadataUnchanged = $true
}

$manifest = [ordered] @{
    schemaVersion = 2
    packs = $releaseRows.ToArray()
}
$manifestPath = Join-Path $distRoot 'asset-pack-manifest.json'
Write-JsonFile -Path $manifestPath -Value $manifest

$reportDocument = [ordered] @{
    schema = 'captioncraft-asset-pack-preparation-report'
    schemaVersion = 2
    version = $Version
    sourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
    stagingRoot = Get-RelativePath -Root $repoRoot -Path $stagingRoot
    distributionRoot = Get-RelativePath -Root $repoRoot -Path $distRoot
    ffmpeg = (& $ffmpeg.Source -hide_banner -version | Select-Object -First 1)
    zipCompression = 'store'
    finalMediaProbes = $finalMediaProbes
    transcodeInputProbes = $transcodeInputProbes
    aviTranscodes = $aviTranscodes
    sourceReadOnlyVerification = 'sha256-size-path-and-last-write-time'
    packs = $reportRows.ToArray()
}
$reportPath = Join-Path $distRoot 'preparation-report.json'
Write-JsonFile -Path $reportPath -Value $reportDocument

Write-Host ''
Write-Host "Prepared manifest: $manifestPath"
foreach ($release in $releaseRows) {
    Write-Host ("{0}: parts={1}, archiveBytes={2}, installedBytes={3}" -f $release.id, @($release.parts).Count, $release.archiveBytes, $release.installedBytes)
}
Write-Host "Verified $finalMediaProbes final media items and preserved both original source trees byte-for-byte."
