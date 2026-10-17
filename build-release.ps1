#requires -version 7.0
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$dist = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $dist.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must stay inside the project.' }
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$archivePath = Join-Path $dist 'CodexMsixUpdater-portable.zip'
$hashPath = Join-Path $dist 'CodexMsixUpdater-portable.zip.sha256'
$sourceItems = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($relative in @('README.md','LICENSE')) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release file is missing: $relative" }
    $sourceItems.Add((Get-Item -LiteralPath $path))
}
foreach ($relative in @('config','src')) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Required release folder is missing: $relative" }
    foreach ($item in Get-ChildItem -LiteralPath $path -Force -Recurse) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release input contains a reparse point: $($item.FullName)" }
        if ($item -is [IO.FileInfo] -and $item.Extension -notin @('.msix','.log')) { $sourceItems.Add($item) }
    }
}
$fileStream = $null
$zip = $null
try {
    $fileStream = [IO.File]::Open($archivePath,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($fileStream,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach ($item in $sourceItems) {
        $entryName = $item.FullName.Substring($root.Length).TrimStart('\').Replace('\','/')
        $entry = $zip.CreateEntry($entryName,[IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($item.FullName)
        $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
    $zip.Dispose(); $zip=$null
    $fileStream.Dispose(); $fileStream=$null
    $hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    [IO.File]::WriteAllText($hashPath, ('{0}  {1}{2}' -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($archivePath), [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $hash
}
finally {
    if ($zip) { $zip.Dispose() }
    if ($fileStream) { $fileStream.Dispose() }
}
