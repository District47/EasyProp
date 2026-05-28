<#
.SYNOPSIS
    SPLAT! Tier-2 regression: coverage-map image output (PPM + PNG).

.DESCRIPTION
    Drives the WritePPM topographic-map path and verifies both:
      (1) the PPM bytes hash to the locked baseline -- proves the
          Phase-2 render refactor stays byte-for-byte non-regressive;
      (2) the PNG decodes to pixels identical to those PPM bytes --
          proves the new PNG writer is faithful to the legacy output.

    Locked baseline lives in tests/golden/coverage_map.ppm.sha256
    (a single 64-char SHA-256 of the PPM file -- the PPM itself, ~26 MB,
    is regenerated per run and not committed).

.PARAMETER UpdateGolden
    Overwrite the SHA-256 baseline with the produced PPM's hash. Use
    after an intentional behavior change.
#>
param(
    [string]$SplatExe = "C:\splat-build\Release\splat.exe",
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$root    = Split-Path -Parent $here
$work    = Join-Path $env:TEMP "splat_image_golden_$([guid]::NewGuid().Guid.Substring(0,8))"
$baseline = Join-Path $here 'golden\coverage_map.ppm.sha256'

if (-not (Test-Path $SplatExe)) {
    Write-Host "FAIL: splat.exe not found at $SplatExe" -ForegroundColor Red
    exit 2
}

# Stage working dir with sample inputs + synthetic SDF tile.
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item "$root\sample_data\wnju-dt.qth" $work -Force
Copy-Item "$root\sample_data\wnju-dt.lrp" $work -Force
& "$here\fixtures\gen_synthetic_sdf.ps1" -OutDir $work | Out-Null

# Run the coverage analysis twice: once -> PPM, once -> PNG. Same inputs,
# same -c range, same SDF tile -> bytes must be identical.
Push-Location $work
try {
    & $SplatExe -t wnju-dt.qth -c 30 -metric -o coverage.ppm > $null
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: PPM run exited $LASTEXITCODE" -ForegroundColor Red; exit 2 }
    & $SplatExe -t wnju-dt.qth -c 30 -metric -o coverage.png > $null
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: PNG run exited $LASTEXITCODE" -ForegroundColor Red; exit 2 }
} finally { Pop-Location }

$ppmFile = Join-Path $work 'coverage.ppm'
$pngFile = Join-Path $work 'coverage.png'
foreach ($f in @($ppmFile, $pngFile)) {
    if (-not (Test-Path $f)) { Write-Host "FAIL: missing $f" -ForegroundColor Red; exit 2 }
}

# (1) PPM byte-identity gate.
$ppmHash = (Get-FileHash $ppmFile -Algorithm SHA256).Hash
if ($UpdateGolden) {
    New-Item -ItemType Directory -Force -Path (Split-Path $baseline) | Out-Null
    Set-Content -Path $baseline -Value $ppmHash -NoNewline -Encoding ascii
    Write-Host "Updated PPM baseline: $baseline = $ppmHash" -ForegroundColor Yellow
} else {
    if (-not (Test-Path $baseline)) { Write-Host "FAIL: no baseline at $baseline (use -UpdateGolden to bake)" -ForegroundColor Red; exit 2 }
    $expHash = (Get-Content $baseline -Raw).Trim()
    if ($ppmHash -ne $expHash) {
        Write-Host "FAIL: PPM bytes diverged from baseline" -ForegroundColor Red
        Write-Host "  expected: $expHash"
        Write-Host "  produced: $ppmHash"
        Write-Host "  Produced file preserved at: $ppmFile"
        exit 1
    }
    Write-Host "PPM bytes match baseline ($ppmHash)" -ForegroundColor Green
}

# (2) PNG-decodes-to-PPM faithfulness gate.
Add-Type -AssemblyName System.Drawing
$ppmBytes = [System.IO.File]::ReadAllBytes($ppmFile)
$nl = 0; $i = 0
while ($nl -lt 3) { if ($ppmBytes[$i] -eq 10) { $nl++ }; $i++ }
$ppmHeaderLen = $i
$ppmPixelCount = $ppmBytes.Length - $ppmHeaderLen

$bmp = [System.Drawing.Bitmap]::FromFile($pngFile)
$rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
$bd   = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                      [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$stride = $bd.Stride
$pngBuf = New-Object byte[] ($stride * $bmp.Height)
[System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $pngBuf, 0, $pngBuf.Length)
$bmp.UnlockBits($bd); $w = $bmp.Width; $h = $bmp.Height; $bmp.Dispose()

if ($ppmPixelCount -ne ($w * $h * 3)) {
    Write-Host "FAIL: pixel-count mismatch (PPM $ppmPixelCount vs $($w*$h*3))" -ForegroundColor Red
    exit 1
}

# System.Drawing returns BGR rows of `stride` bytes; PPM is packed RGB.
$diff = 0
for ($y = 0; $y -lt $h; $y++) {
    $pngRow = $y * $stride
    $ppmRow = $ppmHeaderLen + $y * $w * 3
    for ($x = 0; $x -lt $w; $x++) {
        if ($pngBuf[$pngRow + $x*3]     -ne $ppmBytes[$ppmRow + $x*3 + 2] -or  # B vs B
            $pngBuf[$pngRow + $x*3 + 1] -ne $ppmBytes[$ppmRow + $x*3 + 1] -or  # G vs G
            $pngBuf[$pngRow + $x*3 + 2] -ne $ppmBytes[$ppmRow + $x*3])     {   # R vs R
            $diff++
        }
    }
}

if ($diff -ne 0) {
    Write-Host "FAIL: PNG and PPM differ in $diff / $($w*$h) pixels" -ForegroundColor Red
    exit 1
}
Write-Host "PNG decodes byte-identical to PPM ($($w*$h) pixels)" -ForegroundColor Green
Remove-Item -Recurse -Force $work
Write-Host "PASS" -ForegroundColor Green
exit 0
