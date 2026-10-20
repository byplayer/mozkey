param(
    [ValidateSet("ncaq", "Niccori250k")]
    [string]$Source = "Niccori250k"
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutDir = Join-Path $RepoRoot "src\data\dictionary_koyasi\generated\nico_pixiv"
$OutFile = Join-Path $OutDir "dic-nico-intersection-pixiv-google.txt"

# Resolve the source's current master HEAD on every import.
# Pin that resolved revision only for the duration of this download, so a
# concurrent upstream update cannot mix versions in a single run.
$Repositories = @{
    ncaq = "ncaq/dic-nico-intersection-pixiv"
    Niccori250k = "Niccori250k/dic-nico-intersection-pixiv"
}
$Repository = $Repositories[$Source]
$Ref = "refs/heads/master"
$Remote = "https://github.com/$Repository.git"
$RemoteResult = @(& git ls-remote --heads $Remote $Ref)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve latest dictionary revision: $Remote"
}
if ($RemoteResult.Count -ne 1) {
    throw "Unexpected git ls-remote result count for $Remote ($Ref): $($RemoteResult -join '; ')"
}
$RevisionMatch = [regex]::Match($RemoteResult[0], '^([0-9a-fA-F]{40})\s+refs/heads/master$')
if (-not $RevisionMatch.Success) {
    throw "Unexpected git ls-remote result for $Remote ($Ref): $($RemoteResult[0])"
}
$Revision = $RevisionMatch.Groups[1].Value.ToLowerInvariant()
$Url = "https://raw.githubusercontent.com/$Repository/$Revision/public/dic-nico-intersection-pixiv-google.txt"

New-Item -ItemType Directory -Force $OutDir | Out-Null
$TempFile = Join-Path $OutDir ("dic-nico-intersection-pixiv-google.txt." + [guid]::NewGuid().ToString("N") + ".tmp")

Write-Host "Source: $Source"
Write-Host "Upstream branch: master (latest at download time)"
Write-Host "Resolved revision: $Revision"
Write-Host "Downloading: $Url"
Write-Host "Output: $OutFile"

try {
    Invoke-WebRequest -Uri $Url -OutFile $TempFile -UseBasicParsing
    $Bytes = (Get-Item -LiteralPath $TempFile).Length
    if ($Bytes -lt 5000000) {
        throw "Unexpectedly small nico/pixiv dictionary: $Bytes bytes"
    }
    # Reject truncated or unrecognized content before replacing last known good data.
    $Header = @(Get-Content -LiteralPath $TempFile -Encoding UTF8 -TotalCount 8)
    if (-not (@($Header | Where-Object { $_ -eq '# name: dic-nico-intersection-pixiv' }).Count -gt 0)) {
        throw 'Downloaded file does not look like dic-nico-intersection-pixiv.'
    }
    $ActualHash = (Get-FileHash -LiteralPath $TempFile -Algorithm SHA256).Hash
    $LineCount = (Get-Content -LiteralPath $TempFile -Encoding UTF8 | Measure-Object -Line).Lines
    if ($LineCount -lt 80000 -or $LineCount -gt 250000) {
        throw "Unexpected dictionary line count: $LineCount"
    }
    Move-Item -LiteralPath $TempFile -Destination $OutFile -Force
} finally {
    if (Test-Path -LiteralPath $TempFile) {
        Remove-Item -LiteralPath $TempFile -Force
    }
}

# Record the actual revision and hash for build traceability without freezing
# subsequent imports. This file is under the Git-ignored generated directory.
$Provenance = [ordered]@{
    source = $Source
    repository = $Repository
    upstream_ref = $Ref
    resolved_revision = $Revision
    download_url = $Url
    sha256 = $ActualHash
    bytes = $Bytes
    lines = $LineCount
    retrieved_at_utc = [DateTime]::UtcNow.ToString('o')
}
$ManifestPath = Join-Path $OutDir 'dic-nico-intersection-pixiv-source.json'
$ManifestText = $Provenance | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($ManifestPath, $ManifestText + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'Downloaded and checked:'
Write-Host "  lines: $LineCount"
Write-Host "  bytes: $Bytes"
Write-Host "  sha256: $ActualHash"
Write-Host "  revision: $Revision"
Write-Host "  source-manifest: $ManifestPath"
