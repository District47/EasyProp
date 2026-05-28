<#
.SYNOPSIS
    SPLAT! Tier-2 regression: all four image writers (PPM + PNG, per variant).

.DESCRIPTION
    Drives each of SPLAT!'s map writers in both formats and verifies:
      (1) the PPM bytes hash to the locked baseline -- proves each
          WritePPM* refactor stays byte-for-byte non-regressive;
      (2) the PNG decodes to pixels identical to those PPM bytes --
          proves the corresponding PNG path is faithful.

    Variants covered (run with -L 30 / -c 30 against the synthetic SDF):
      topo   WritePPM     (-c 30)              topographic
      lr     WritePPMLR   (-L 30 -erp 0)       path-loss map (ERP forced 0)
      ss     WritePPMSS   (-L 30)              signal strength
      dbm    WritePPMDBM  (-L 30 -dbm)         dBm power

    Each variant has its own SHA-256 baseline at
        tests/golden/<variant>.ppm.sha256
    (the ~25 MB PPM itself is regenerated per run and not committed).

.PARAMETER UpdateGolden
    Overwrite all baselines with whatever the current build produces.
    Use after an intentional behavior change.

.PARAMETER Only
    Run just one variant (topo, lr, ss, dbm). Useful for bisecting.
#>
param(
    [string]$SplatExe = "C:\splat-build\Release\splat.exe",
    [switch]$UpdateGolden,
    [ValidateSet('topo','lr','ss','dbm','all')][string]$Only = 'all'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$work = Join-Path $env:TEMP "splat_image_golden_$([guid]::NewGuid().Guid.Substring(0,8))"

if (-not (Test-Path $SplatExe)) {
    Write-Host "FAIL: splat.exe not found at $SplatExe" -ForegroundColor Red
    exit 2
}

# Variant table: id, splat args (without -o), baseline hash file basename.
$variants = @(
    @{ id='topo'; args=@('-t','wnju-dt.qth','-c','30','-metric')                 ; base='topo.ppm.sha256'     ; writer='WritePPM'    },
    @{ id='lr'  ; args=@('-t','wnju-dt.qth','-L','30','-metric','-erp','0')      ; base='lr.ppm.sha256'       ; writer='WritePPMLR'  },
    @{ id='ss'  ; args=@('-t','wnju-dt.qth','-L','30','-metric')                 ; base='ss.ppm.sha256'       ; writer='WritePPMSS'  },
    @{ id='dbm' ; args=@('-t','wnju-dt.qth','-L','30','-metric','-dbm')          ; base='dbm.ppm.sha256'      ; writer='WritePPMDBM' }
)

if ($Only -ne 'all') {
    $variants = $variants | Where-Object { $_.id -eq $Only }
}

# Stage clean working dir + synthetic SDF + sample inputs (done once for all variants).
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item "$root\sample_data\wnju-dt.qth" $work -Force
Copy-Item "$root\sample_data\wnju-dt.lrp" $work -Force
& "$here\fixtures\gen_synthetic_sdf.ps1" -OutDir $work | Out-Null

Add-Type -AssemblyName System.Drawing

function Compare-PngToPpm {
    param([string]$Ppm, [string]$Png)
    $ppmBytes = [System.IO.File]::ReadAllBytes($Ppm)
    $nl=0; $i=0; while ($nl -lt 3) { if ($ppmBytes[$i] -eq 10) { $nl++ }; $i++ }
    $ppmHdr = $i
    $bmp = [System.Drawing.Bitmap]::FromFile($Png)
    $rect = New-Object System.Drawing.Rectangle 0,0,$bmp.Width,$bmp.Height
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride=$bd.Stride
    $pngBuf = New-Object byte[] ($stride*$bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $pngBuf, 0, $pngBuf.Length)
    $bmp.UnlockBits($bd); $w=$bmp.Width; $h=$bmp.Height; $bmp.Dispose()
    $diff=0
    for ($y=0; $y -lt $h; $y++) {
        $pr=$y*$stride; $qr=$ppmHdr+$y*$w*3
        for ($x=0; $x -lt $w; $x++) {
            if ($pngBuf[$pr+$x*3]   -ne $ppmBytes[$qr+$x*3+2] -or
                $pngBuf[$pr+$x*3+1] -ne $ppmBytes[$qr+$x*3+1] -or
                $pngBuf[$pr+$x*3+2] -ne $ppmBytes[$qr+$x*3])  { $diff++ }
        }
    }
    return @{ W=$w; H=$h; Diffs=$diff }
}

$failed = 0
foreach ($v in $variants) {
    $id = $v.id
    $base = $v.base
    $writer = $v.writer
    $ppm = Join-Path $work "$id.ppm"
    $png = Join-Path $work "$id.png"
    $baselineF = Join-Path $here "golden\$base"
    Write-Host "[$id  $writer]" -ForegroundColor Cyan

    Push-Location $work
    try {
        & $SplatExe @($v.args) -o "$id.ppm" > $null
        if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: PPM run exited $LASTEXITCODE" -ForegroundColor Red; $failed++; Pop-Location; continue }
        & $SplatExe @($v.args) -o "$id.png" > $null
        if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: PNG run exited $LASTEXITCODE" -ForegroundColor Red; $failed++; Pop-Location; continue }
    } finally { Pop-Location }

    if (-not (Test-Path $ppm) -or -not (Test-Path $png)) {
        Write-Host "  FAIL: missing output(s)" -ForegroundColor Red; $failed++; continue
    }

    # (1) PPM hash gate.
    $ppmHash = (Get-FileHash $ppm -Algorithm SHA256).Hash
    if ($UpdateGolden) {
        New-Item -ItemType Directory -Force -Path (Split-Path $baselineF) | Out-Null
        Set-Content -Path $baselineF -Value $ppmHash -NoNewline -Encoding ascii
        Write-Host "  baked baseline $ppmHash" -ForegroundColor Yellow
    } else {
        if (-not (Test-Path $baselineF)) { Write-Host "  FAIL: no baseline at $baselineF" -ForegroundColor Red; $failed++; continue }
        $exp = (Get-Content $baselineF -Raw).Trim()
        if ($exp -ne $ppmHash) {
            Write-Host "  FAIL: PPM hash drift" -ForegroundColor Red
            Write-Host "    expected $exp"
            Write-Host "    produced $ppmHash"
            $failed++
            continue
        }
        Write-Host "  PPM bytes match baseline ($ppmHash)" -ForegroundColor Green
    }

    # (2) PNG faithfulness gate.
    $cmp = Compare-PngToPpm -Ppm $ppm -Png $png
    if ($cmp.Diffs -ne 0) {
        Write-Host ("  FAIL: PNG differs from PPM in {0} / {1} pixels" -f $cmp.Diffs, ($cmp.W*$cmp.H)) -ForegroundColor Red
        $failed++
        continue
    }
    Write-Host ("  PNG decodes byte-identical to PPM ({0}x{1} = {2} pixels)" -f $cmp.W, $cmp.H, ($cmp.W*$cmp.H)) -ForegroundColor Green
}

Remove-Item -Recurse -Force $work
if ($failed -eq 0) { Write-Host "PASS (all $($variants.Count) variants)" -ForegroundColor Green; exit 0 }
Write-Host "FAIL ($failed of $($variants.Count) variants failed)" -ForegroundColor Red
exit 1
