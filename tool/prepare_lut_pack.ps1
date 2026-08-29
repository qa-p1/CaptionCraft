[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PackManifest,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PreviewSource,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '1.0.0',

    [Parameter()]
    [ValidateRange(1048576, 503316480)]
    [long] $MaxPartBytes = 471859200,

    [Parameter()]
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:FixedZipTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$script:StableIdPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
$script:MaximumLutBytes = 67108864L

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
    return $candidateFull.StartsWith(
        "$parentFull$([System.IO.Path]::DirectorySeparatorChar)",
        (Get-PathComparison)
    )
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
        throw "Unsafe sourcePath '$RelativePath'."
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $nativeRelative = $portable.Replace(
        '/',
        [System.IO.Path]::DirectorySeparatorChar
    )
    $resolved = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($rootFull, $nativeRelative)
    )
    if (-not (Test-IsPathWithin -Parent $rootFull -Candidate $resolved)) {
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

    if ($Object.PSObject.Properties.Name -cnotcontains $Name) {
        throw "$Context is missing '$Name'."
    }
    return $Object.$Name
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )

    $value = Get-RequiredProperty -Object $Object -Name $Name -Context $Context
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        throw "$Context has an invalid '$Name'."
    }
    return $value.Trim()
}

function Get-OptionalString {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Object.PSObject.Properties.Name -cnotcontains $Name) {
        return $null
    }
    $value = $Object.$Name
    if ($null -eq $value) {
        return $null
    }
    if ($value -isnot [string]) {
        throw "Optional field '$Name' must be a string."
    }
    $trimmed = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }
    return $trimmed
}

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Context
    )

    $uri = $null
    if (
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -cne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment)
    ) {
        throw "$Context must be a public HTTPS URL."
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )

    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, "$json`n", $script:Utf8NoBom)
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)

    return @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject] @{
                    relativePath = Get-RelativePath -Root $Root -Path $_.FullName
                    sizeBytes = [long] $_.Length
                    lastWriteUtcTicks = [long] $_.LastWriteTimeUtc.Ticks
                    sha256 = Get-Sha256 -Path $_.FullName
                }
            }
    )
}

function Assert-SnapshotsEqual {
    param(
        [Parameter(Mandatory)] [object[]] $Expected,
        [Parameter(Mandatory)] [object[]] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw 'The LUT source tree changed during preparation.'
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
            throw "The LUT source tree changed at '$($left.relativePath)'."
        }
    }
}

function Get-SnapshotFingerprint {
    param([Parameter(Mandatory)] [object[]] $Snapshot)

    $canonical = $Snapshot | ConvertTo-Json -Compress -Depth 5
    $bytes = $script:Utf8NoBom.GetBytes($canonical)
    return [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
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
    }
    finally {
        $process.Dispose()
    }
}

function ConvertTo-FfmpegFilterPath {
    param([Parameter(Mandatory)] [string] $Path)

    return $Path.Replace('\', '/').Replace(':', '\:').Replace("'", "\'").Replace('[', '\[').Replace(']', '\]')
}

function Get-LutGridSize {
    param([Parameter(Mandatory)] [System.IO.FileInfo] $File)

    $lines = @(Get-Content -LiteralPath $File.FullName -TotalCount 4096)
    if ($File.Extension -ieq '.cube') {
        foreach ($line in $lines) {
            $match = [regex]::Match($line.Trim(), '^LUT_(?:1D|3D)_SIZE\s+(\d+)\s*$')
            if ($match.Success) {
                $size = [int] $match.Groups[1].Value
                if ($size -ge 2) {
                    return $size
                }
            }
        }
        throw "CUBE LUT '$($File.FullName)' is missing a valid LUT size."
    }
    foreach ($line in $lines) {
        if ($line.Trim() -match '^\d+(?:\s+\d+){3,}$') {
            return $null
        }
    }
    throw "3DL LUT '$($File.FullName)' is missing a numeric mesh row."
}

function Invoke-LutRender {
    param(
        [Parameter(Mandatory)] [string] $Ffmpeg,
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $LutPath,
        [Parameter()] [AllowNull()] [string] $OutputPath
    )

    $escaped = ConvertTo-FfmpegFilterPath -Path $LutPath
    $filter = "lut3d=file='$escaped',scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2:black"
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', $InputPath, '-vf', $filter, '-frames:v', '1')) {
        $arguments.Add($argument)
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        foreach ($argument in @('-f', 'null', '-')) {
            $arguments.Add($argument)
        }
    }
    else {
        foreach ($argument in @('-an', '-q:v', '3', $OutputPath)) {
            $arguments.Add($argument)
        }
    }
    Invoke-CheckedProcess -Executable $Ffmpeg -Arguments $arguments.ToArray() -Description "Rendering LUT '$LutPath'"
}

function New-ZipArchive {
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $Files
    )

    Add-Type -AssemblyName System.IO.Compression
    $stream = [System.IO.FileStream]::new(
        $ArchivePath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            $script:Utf8NoBom
        )
        try {
            foreach ($file in $Files) {
                $entryName = Get-RelativePath -Root $SourceDirectory -Path $file.FullName
                $entry = $archive.CreateEntry(
                    $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
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
        $stream.Dispose()
    }
}

function New-ArchiveParts {
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
            throw "File '$($file.FullName)' is too large for an archive part."
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
        $temporary = Join-Path $DistributionDirectory "luts-$PackVersion-$partId.zip.part"
        New-ZipArchive -SourceDirectory $SourceDirectory -ArchivePath $temporary -Files $groups[$index]
        $sha256 = Get-Sha256 -Path $temporary
        $archiveName = "luts-$PackVersion-$partId-$($sha256.Substring(0, 12)).zip"
        $archivePath = Join-Path $DistributionDirectory $archiveName
        [System.IO.File]::Move($temporary, $archivePath)
        $bytes = [long] (Get-Item -LiteralPath $archivePath).Length
        if ($bytes -gt $MaximumPartBytes) {
            throw "Generated archive '$archiveName' exceeds the configured limit."
        }
        $parts.Add([ordered] @{
            id = $partId
            url = "./packs/luts/$PackVersion/$archiveName"
            sha256 = $sha256
            bytes = $bytes
        })
    }
    return $parts.ToArray()
}

function Remove-WorkDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Parent
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (
        -not (Test-IsPathWithin -Parent $Parent -Candidate $Path) -or
        -not ([System.IO.Path]::GetFileName($Path).StartsWith('.work-'))
    ) {
        throw "Refusing to remove unverified work directory '$Path'."
    }
    [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($Path), $true)
}

$sourceDirectory = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path)
$manifestPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PackManifest -ErrorAction Stop).Path)
$previewPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PreviewSource -ErrorAction Stop).Path)
if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    throw 'SourceRoot must be a directory.'
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'PackManifest must be a JSON file.'
}
if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) {
    throw 'PreviewSource must be an image or video file.'
}
if ((Get-Item -LiteralPath $previewPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw 'PreviewSource cannot be a link or reparse point.'
}
$linkedSourceEntry = Get-ChildItem -LiteralPath $sourceDirectory -Force -Recurse |
    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
    Select-Object -First 1
if ($null -ne $linkedSourceEntry) {
    throw "LUT source contains a link or reparse point: '$($linkedSourceEntry.FullName)'."
}

$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if (
    (Get-RequiredString -Object $manifest -Name 'schema' -Context 'Manifest') -cne 'captioncraft-lut-source-manifest' -or
    [int] (Get-RequiredProperty -Object $manifest -Name 'schemaVersion' -Context 'Manifest') -ne 1
) {
    throw 'LUT source manifest must use captioncraft-lut-source-manifest schema 1.'
}
$pack = Get-RequiredProperty -Object $manifest -Name 'pack' -Context 'Manifest'
if ((Get-RequiredString -Object $pack -Name 'id' -Context 'Manifest pack') -cne 'luts') {
    throw "Manifest pack.id must be 'luts'."
}
$packTitle = Get-RequiredString -Object $pack -Name 'title' -Context 'Manifest pack'
$review = Get-RequiredProperty -Object $manifest -Name 'review' -Context 'Manifest'
if ((Get-RequiredProperty -Object $review -Name 'redistributionRightsConfirmed' -Context 'Manifest review') -ne $true) {
    throw 'Manifest review must confirm redistribution rights.'
}
$preview = Get-RequiredProperty -Object $manifest -Name 'preview' -Context 'Manifest'
$previewSha256 = Get-RequiredString -Object $preview -Name 'expectedSha256' -Context 'Manifest preview'
if ($previewSha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-Sha256 -Path $previewPath) -cne $previewSha256.ToLowerInvariant()) {
    throw 'PreviewSource does not match manifest preview.expectedSha256.'
}
if ((Get-RequiredProperty -Object $preview -Name 'redistributionCleared' -Context 'Manifest preview') -ne $true) {
    throw 'Manifest preview must be redistribution-cleared.'
}
$previewLicense = Get-RequiredString -Object $preview -Name 'license' -Context 'Manifest preview'
$previewLicenseUrl = Get-RequiredString -Object $preview -Name 'licenseUrl' -Context 'Manifest preview'
$previewSourceUrl = Get-RequiredString -Object $preview -Name 'sourceUrl' -Context 'Manifest preview'
Assert-HttpsUrl -Value $previewLicenseUrl -Context 'preview.licenseUrl'
Assert-HttpsUrl -Value $previewSourceUrl -Context 'preview.sourceUrl'

$sourceSnapshotBefore = @(Get-TreeSnapshot -Root $sourceDirectory)
$sourceTreeSha256 = Get-SnapshotFingerprint -Snapshot $sourceSnapshotBefore
$lutFiles = @(
    Get-ChildItem -LiteralPath $sourceDirectory -Force -Recurse -File |
        Where-Object { $_.Extension -ieq '.cube' -or $_.Extension -ieq '.3dl' } |
        Sort-Object FullName
)
if ($lutFiles.Count -eq 0 -or $lutFiles.Count -gt 10000) {
    throw 'SourceRoot must contain between 1 and 10000 CUBE or 3DL files.'
}
$rawAssets = @(Get-RequiredProperty -Object $manifest -Name 'assets' -Context 'Manifest')
if ($rawAssets.Count -ne $lutFiles.Count) {
    throw 'Manifest assets must declare every LUT file exactly once.'
}

$declaredPaths = [System.Collections.Generic.HashSet[string]]::new((Get-PathComparer))
$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$categories = [ordered] @{}
$descriptors = [System.Collections.Generic.List[object]]::new()
foreach ($asset in $rawAssets) {
    $context = 'Manifest LUT asset'
    $id = Get-RequiredString -Object $asset -Name 'id' -Context $context
    $categoryId = Get-RequiredString -Object $asset -Name 'categoryId' -Context $context
    if ($id -cnotmatch $script:StableIdPattern -or -not $ids.Add($id)) {
        throw "LUT asset id '$id' is invalid or duplicated."
    }
    if ($categoryId -cnotmatch $script:StableIdPattern) {
        throw "LUT category id '$categoryId' is invalid."
    }
    $categoryName = Get-RequiredString -Object $asset -Name 'categoryName' -Context $context
    if ($categories.Contains($categoryId) -and $categories[$categoryId] -cne $categoryName) {
        throw "LUT category '$categoryId' has conflicting names."
    }
    $categories[$categoryId] = $categoryName
    $sourcePath = Get-RequiredString -Object $asset -Name 'sourcePath' -Context $context
    $sourceFilePath = Resolve-SafeChildPath -Root $sourceDirectory -RelativePath $sourcePath
    $sourceFile = Get-Item -LiteralPath $sourceFilePath -ErrorAction Stop
    if (-not $declaredPaths.Add($sourceFile.FullName)) {
        throw "LUT sourcePath '$sourcePath' is duplicated."
    }
    if ($sourceFile.Extension -ine '.cube' -and $sourceFile.Extension -ine '.3dl') {
        throw "LUT '$sourcePath' must use .cube or .3dl."
    }
    if ($sourceFile.Length -le 0 -or $sourceFile.Length -gt $script:MaximumLutBytes) {
        throw "LUT '$sourcePath' has an unsupported size."
    }
    $expectedSha256 = Get-RequiredString -Object $asset -Name 'expectedSha256' -Context $context
    $sourceSha256 = Get-Sha256 -Path $sourceFile.FullName
    if ($expectedSha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $sourceSha256 -cne $expectedSha256.ToLowerInvariant()) {
        throw "LUT '$sourcePath' does not match expectedSha256."
    }
    if ((Get-RequiredProperty -Object $asset -Name 'redistributionCleared' -Context $context) -ne $true) {
        throw "LUT '$sourcePath' is not redistribution-cleared."
    }
    $license = Get-RequiredString -Object $asset -Name 'license' -Context $context
    $licenseUrl = Get-RequiredString -Object $asset -Name 'licenseUrl' -Context $context
    $sourceUrl = Get-RequiredString -Object $asset -Name 'sourceUrl' -Context $context
    Assert-HttpsUrl -Value $licenseUrl -Context "$sourcePath licenseUrl"
    Assert-HttpsUrl -Value $sourceUrl -Context "$sourcePath sourceUrl"
    $gridSize = Get-LutGridSize -File $sourceFile
    Invoke-LutRender -Ffmpeg $ffmpeg -InputPath $previewPath -LutPath $sourceFile.FullName -OutputPath $null
    $tags = @()
    if ($asset.PSObject.Properties.Name -ccontains 'tags') {
        $tags = @($asset.tags | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    }
    $descriptors.Add([pscustomobject] @{
        id = $id
        title = Get-RequiredString -Object $asset -Name 'title' -Context $context
        categoryId = $categoryId
        categoryName = $categoryName
        sourceFile = $sourceFile
        sourcePath = Get-RelativePath -Root $sourceDirectory -Path $sourceFile.FullName
        sourceSha256 = $sourceSha256
        extension = $sourceFile.Extension.ToLowerInvariant()
        format = $sourceFile.Extension.TrimStart('.').ToLowerInvariant()
        gridSize = $gridSize
        license = $license
        licenseUrl = $licenseUrl
        sourceUrl = $sourceUrl
        creator = Get-OptionalString -Object $asset -Name 'creator'
        attribution = Get-OptionalString -Object $asset -Name 'attribution'
        tags = $tags
    })
}
foreach ($file in $lutFiles) {
    if (-not $declaredPaths.Contains($file.FullName)) {
        throw "Undeclared LUT file '$((Get-RelativePath -Root $sourceDirectory -Path $file.FullName))'."
    }
}

Assert-SnapshotsEqual -Expected $sourceSnapshotBefore -Actual @(Get-TreeSnapshot -Root $sourceDirectory)
if ($ValidateOnly) {
    Write-Host "Validated $($descriptors.Count) LUT files. ValidateOnly created no staging files."
    exit 0
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stagingParent = Join-Path $repoRoot 'tool\asset_pack_staging\luts'
$distributionParent = Join-Path $repoRoot 'tool\asset_pack_dist\packs\luts'
$stagingFinal = Join-Path $stagingParent $Version
$distributionFinal = Join-Path $distributionParent $Version
if (Test-Path -LiteralPath $stagingFinal) {
    throw "Refusing to overwrite staging release '$stagingFinal'."
}
if (Test-Path -LiteralPath $distributionFinal) {
    throw "Refusing to overwrite distribution release '$distributionFinal'."
}
[void] [System.IO.Directory]::CreateDirectory($stagingParent)
[void] [System.IO.Directory]::CreateDirectory($distributionParent)
$workName = ".work-$PID-$([guid]::NewGuid().ToString('N'))"
$stagingWork = Join-Path $stagingParent $workName
$distributionWork = Join-Path $distributionParent $workName
[void] [System.IO.Directory]::CreateDirectory((Join-Path $stagingWork 'luts'))
[void] [System.IO.Directory]::CreateDirectory((Join-Path $stagingWork 'previews'))
[void] [System.IO.Directory]::CreateDirectory($distributionWork)
$stagingMoved = $false
$distributionMoved = $false
try {
    $catalogAssets = [System.Collections.Generic.List[object]]::new()
    foreach ($descriptor in @($descriptors | Sort-Object id)) {
        $relativePath = "luts/$($descriptor.id)$($descriptor.extension)"
        $previewRelativePath = "previews/$($descriptor.id).jpg"
        $targetLut = Resolve-SafeChildPath -Root $stagingWork -RelativePath $relativePath
        $targetPreview = Resolve-SafeChildPath -Root $stagingWork -RelativePath $previewRelativePath
        [System.IO.File]::Copy($descriptor.sourceFile.FullName, $targetLut, $false)
        Invoke-LutRender -Ffmpeg $ffmpeg -InputPath $previewPath -LutPath $targetLut -OutputPath $targetPreview
        $metadata = [ordered] @{
            format = $descriptor.format
            license = $descriptor.license
            licenseUrl = $descriptor.licenseUrl
            sourceUrl = $descriptor.sourceUrl
            redistributionCleared = $true
            sourceSha256 = $descriptor.sourceSha256
            previewSourceSha256 = $previewSha256.ToLowerInvariant()
        }
        if ($null -ne $descriptor.gridSize) {
            $metadata.gridSize = [int] $descriptor.gridSize
        }
        if ($null -ne $descriptor.creator) {
            $metadata.creator = $descriptor.creator
        }
        if ($null -ne $descriptor.attribution) {
            $metadata.attribution = $descriptor.attribution
        }
        $catalogAssets.Add([ordered] @{
            id = $descriptor.id
            title = $descriptor.title
            categoryId = $descriptor.categoryId
            mediaType = 'lut'
            relativePath = $relativePath
            previewPath = $previewRelativePath
            sizeBytes = [long] (Get-Item -LiteralPath $targetLut).Length
            hasAudio = $false
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
            id = 'luts'
            title = $packTitle
            version = $Version
        }
        categories = $catalogCategories.ToArray()
        assets = $catalogAssets.ToArray()
    }
    Write-JsonFile -Path (Join-Path $stagingWork 'db.json') -Value $catalog

    $installedFiles = @(Get-ChildItem -LiteralPath $stagingWork -Force -Recurse -File)
    $installedBytes = [long] (($installedFiles | Measure-Object Length -Sum).Sum)
    $archiveParts = @(New-ArchiveParts -SourceDirectory $stagingWork -DistributionDirectory $distributionWork -PackVersion $Version -MaximumPartBytes $MaxPartBytes)
    $release = [ordered] @{
        schema = 'captioncraft-asset-pack-release'
        schemaVersion = 2
        pack = [ordered] @{
            id = 'luts'
            version = $Version
            title = $packTitle
            description = 'Previewable color looks for offline use in CaptionCraft.'
            assetCount = $descriptors.Count
            installedBytes = $installedBytes
            catalogPath = 'db.json'
            catalogSchemaVersion = 3
            minAppBuild = 2005
            parts = $archiveParts
        }
        audit = [ordered] @{
            assets = $descriptors.Count
            sourceTreeSha256 = $sourceTreeSha256
            sourceManifestSha256 = Get-Sha256 -Path $manifestPath
            previewSourceSha256 = $previewSha256.ToLowerInvariant()
            previewLicense = $previewLicense
            previewLicenseUrl = $previewLicenseUrl
            previewSourceUrl = $previewSourceUrl
            redistributionRightsConfirmed = $true
        }
    }
    $fingerprintBytes = $script:Utf8NoBom.GetBytes(($archiveParts | ConvertTo-Json -Compress -Depth 8))
    $fingerprint = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($fingerprintBytes)
    ).ToLowerInvariant()
    $releaseName = "luts-$Version-$($fingerprint.Substring(0, 12)).release.json"
    Write-JsonFile -Path (Join-Path $distributionWork $releaseName) -Value $release

    Assert-SnapshotsEqual -Expected $sourceSnapshotBefore -Actual @(Get-TreeSnapshot -Root $sourceDirectory)
    [System.IO.Directory]::Move($distributionWork, $distributionFinal)
    $distributionMoved = $true
    [System.IO.Directory]::Move($stagingWork, $stagingFinal)
    $stagingMoved = $true
    Write-Host "Prepared LUT catalog: $(Join-Path $stagingFinal 'db.json')"
    Write-Host "Prepared release metadata: $(Join-Path $distributionFinal $releaseName)"
    Write-Host "assets=$($descriptors.Count), parts=$($archiveParts.Count), installedBytes=$installedBytes"
}
catch {
    if (-not $stagingMoved) {
        Remove-WorkDirectory -Path $stagingWork -Parent $stagingParent
    }
    if (-not $distributionMoved) {
        Remove-WorkDirectory -Path $distributionWork -Parent $distributionParent
    }
    throw
}
