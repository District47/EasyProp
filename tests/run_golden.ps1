<#
.SYNOPSIS
    SPLAT! Tier-1 regression: point-to-point path report on a uniform-terrain SDF.

.DESCRIPTION
    End-to-end smoke + golden-output check. Exercises the full pipeline:
    QTH/LRP parse -> LoadSDF -> DEM accessors -> ReadPath -> ITWOM
    point_to_point -> ObstructionAnalysis -> PathReport text output.

    Stages a clean working dir, generates a deterministic synthetic SDF tile,
    runs splat with a fixed command, and diffs the produced path report
    against tests/golden/path_report.txt.

    Exit codes: 0 = match, 1 = mismatch, 2 = build/run failure.

.PARAMETER SplatExe
    Path to the built splat.exe (default: C:\splat-build\Release\splat.exe).

.PARAMETER UpdateGolden
    Overwrite tests/golden/path_report.txt with the produced output instead of
    comparing -- use after an intentional behavior change.
#>
param(
    [string]$SplatExe = "C:\splat-build\Release\splat.exe",
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$root    = Split-Path -Parent $here
$work    = Join-Path $env:TEMP "splat_golden_$([guid]::NewGuid().Guid.Substring(0,8))"
$goldenF = Join-Path $here 'golden\path_report.txt'

if (-not (Test-Path $SplatExe)) {
    Write-Host "FAIL: splat.exe not found at $SplatExe" -ForegroundColor Red
    exit 2
}

New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item "$root\sample_data\wnju-dt.qth" $work -Force
Copy-Item "$root\sample_data\wnju-dt.lrp" $work -Force
Copy-Item "$here\fixtures\rx-near.qth"    $work -Force
& "$here\fixtures\gen_synthetic_sdf.ps1" -OutDir $work | Out-Null

Push-Location $work
try {
    & $SplatExe -t wnju-dt.qth -r rx-near.qth -metric > $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: splat exited with code $LASTEXITCODE" -ForegroundColor Red
        exit 2
    }
} finally { Pop-Location }

$produced = Join-Path $work 'WNJU-DT-to-RX-NEAR.txt'
if (-not (Test-Path $produced)) {
    Write-Host "FAIL: expected output file not produced" -ForegroundColor Red
    exit 2
}

if ($UpdateGolden) {
    Copy-Item $produced $goldenF -Force
    Write-Host "Updated golden: $goldenF" -ForegroundColor Yellow
    exit 0
}

# Compare content with line endings normalized to LF -- splat writes CRLF in
# text mode on Windows, but the golden file is stored LF in the repo. We want
# the same SHA-256 on both platforms regardless of how git checked the file
# out, so normalize before hashing.
function Get-NormalizedSha256 {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path) | Where-Object { $_ -ne 13 }  # strip CR
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try   { ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}
$actHash = Get-NormalizedSha256 $produced
$expHash = Get-NormalizedSha256 $goldenF

if ($actHash -eq $expHash) {
    Write-Host "PASS  ($actHash)" -ForegroundColor Green
    Remove-Item -Recurse -Force $work
    exit 0
}

Write-Host "FAIL: path-report mismatch" -ForegroundColor Red
Write-Host "  expected SHA256 $expHash"
Write-Host "  produced SHA256 $actHash"
Write-Host "  diff (expected vs produced):"
Compare-Object (Get-Content $goldenF) (Get-Content $produced) | Format-Table -AutoSize
Write-Host "Produced output preserved at: $produced"
exit 1
