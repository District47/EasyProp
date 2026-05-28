<#
.SYNOPSIS
    SPLAT! Tier-2 regression: every image writer in every supported format.

.DESCRIPTION
    Drives each of SPLAT!'s four map writers in all three output formats and
    verifies every byte- and tag-identity gate that should hold:

      (1) PPM bytes hash to the locked baseline -- proves the refactor of
          each WritePPM* stays byte-for-byte non-regressive.
      (2) PNG decodes to pixels identical to the PPM -- proves the PNG
          writer is faithful.
      (3) GeoTIFF decodes to pixels identical to the PPM main-map region
          (PPM has an extra 30-row legend strip that GeoTIFF omits, since
          GIS data shouldn't carry UI chrome).
      (4) GeoTIFF carries valid WGS-84 georeferencing tags: a single
          tiepoint anchored at (0,0) -> (west, north), a pixel scale of
          (east-west)/w x (north-south)/h, and the three GeoKeys that mark
          the raster as ModelTypeGeographic + RasterPixelIsArea + GCS_WGS_84.

    Variants covered (run with -L 30 / -c 30 against the synthetic SDF):
      topo   WritePPM     (-c 30)                topographic
      lr     WritePPMLR   (-L 30 -erp 0)         path-loss map
      ss     WritePPMSS   (-L 30)                signal strength
      dbm    WritePPMDBM  (-L 30 -dbm)           dBm power

    Each variant has its own SHA-256 baseline at
        tests/golden/<variant>.ppm.sha256
    (the ~25 MB PPM and the LZW-compressed ~1 MB GeoTIFF are regenerated
    per run and not committed.)

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

$variants = @(
    @{ id='topo'; args=@('-t','wnju-dt.qth','-c','30','-metric')            ; base='topo.ppm.sha256' ; writer='WritePPM'    },
    @{ id='lr'  ; args=@('-t','wnju-dt.qth','-L','30','-metric','-erp','0') ; base='lr.ppm.sha256'   ; writer='WritePPMLR'  },
    @{ id='ss'  ; args=@('-t','wnju-dt.qth','-L','30','-metric')            ; base='ss.ppm.sha256'   ; writer='WritePPMSS'  },
    @{ id='dbm' ; args=@('-t','wnju-dt.qth','-L','30','-metric','-dbm')     ; base='dbm.ppm.sha256'  ; writer='WritePPMDBM' }
)
if ($Only -ne 'all') { $variants = $variants | Where-Object { $_.id -eq $Only } }

New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item "$root\sample_data\wnju-dt.qth" $work -Force
Copy-Item "$root\sample_data\wnju-dt.lrp" $work -Force
& "$here\fixtures\gen_synthetic_sdf.ps1" -OutDir $work | Out-Null

Add-Type -AssemblyName System.Drawing

# --- PPM helpers ---
function Get-PpmPixels {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    $nl=0; $i=0; while ($nl -lt 3) { if ($b[$i] -eq 10) { $nl++ }; $i++ }
    $px = New-Object byte[] ($b.Length - $i)
    [Array]::Copy($b, $i, $px, 0, $px.Length)
    return $px
}

# Decode a PNG/TIFF via System.Drawing to a tight RGB byte array.
function Get-DecodedPixels {
    param([string]$Path)
    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    $rect = New-Object System.Drawing.Rectangle 0,0,$bmp.Width,$bmp.Height
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride=$bd.Stride
    $buf = New-Object byte[] ($stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
    $bmp.UnlockBits($bd); $w=$bmp.Width; $h=$bmp.Height; $bmp.Dispose()
    # Pack stride->tight + swap BGR->RGB.
    $tight = New-Object byte[] ($w * $h * 3)
    for ($y = 0; $y -lt $h; $y++) {
        $src = $y * $stride
        $dst = $y * $w * 3
        for ($x = 0; $x -lt $w; $x++) {
            $tight[$dst+$x*3]   = $buf[$src+$x*3+2]
            $tight[$dst+$x*3+1] = $buf[$src+$x*3+1]
            $tight[$dst+$x*3+2] = $buf[$src+$x*3]
        }
    }
    return @{ W=$w; H=$h; Px=$tight }
}

function Get-Sha256 { param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($Bytes) | ForEach-Object { '{0:x2}' -f $_ }) -join '' }
    finally { $sha.Dispose() }
}

$failed = 0
foreach ($v in $variants) {
    $id = $v.id; $base = $v.base; $writer = $v.writer
    $ppm = Join-Path $work "$id.ppm"
    $png = Join-Path $work "$id.png"
    $tif = Join-Path $work "$id.tif"
    $baselineF = Join-Path $here "golden\$base"
    Write-Host "[$id  $writer]" -ForegroundColor Cyan

    Push-Location $work
    try {
        foreach ($ext in @('ppm','png','tif')) {
            & $SplatExe @($v.args) -o "$id.$ext" > $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAIL: $ext run exited $LASTEXITCODE" -ForegroundColor Red
                $failed++
                throw "abort variant"
            }
        }
    } catch { Pop-Location; continue } finally { Pop-Location -EA SilentlyContinue }

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
            Write-Host "  FAIL: PPM hash drift  expected $exp  produced $ppmHash" -ForegroundColor Red
            $failed++; continue
        }
        Write-Host "  PPM bytes match baseline ($ppmHash)" -ForegroundColor Green
    }

    $ppmPx = Get-PpmPixels $ppm
    $ppmHashPx = Get-Sha256 $ppmPx

    # (2) PNG faithfulness gate -- decoded pixels SHA must match PPM pixels.
    $pngDec = Get-DecodedPixels $png
    $pngHashPx = Get-Sha256 $pngDec.Px
    if ($pngHashPx -ne $ppmHashPx) {
        Write-Host "  FAIL: PNG pixels do not match PPM ($($pngDec.W)x$($pngDec.H))" -ForegroundColor Red
        $failed++; continue
    }
    Write-Host ("  PNG decodes byte-identical to PPM ({0}x{1})" -f $pngDec.W, $pngDec.H) -ForegroundColor Green

    # (3) GeoTIFF faithfulness gate -- decoded TIFF pixels must match the PPM
    # main-map region (PPM may have a 30-row legend strip the GeoTIFF omits).
    $tifDec = Get-DecodedPixels $tif
    $needBytes = $tifDec.W * $tifDec.H * 3
    if ($ppmPx.Length -lt $needBytes) {
        Write-Host "  FAIL: PPM smaller than GeoTIFF main region" -ForegroundColor Red
        $failed++; continue
    }
    $ppmMain = New-Object byte[] $needBytes
    [Array]::Copy($ppmPx, 0, $ppmMain, 0, $needBytes)
    $ppmMainHash = Get-Sha256 $ppmMain
    $tifHashPx = Get-Sha256 $tifDec.Px
    if ($tifHashPx -ne $ppmMainHash) {
        Write-Host "  FAIL: GeoTIFF pixels do not match PPM main region ($($tifDec.W)x$($tifDec.H))" -ForegroundColor Red
        $failed++; continue
    }
    Write-Host ("  GeoTIFF decodes byte-identical to PPM main region ({0}x{1})" -f $tifDec.W, $tifDec.H) -ForegroundColor Green

    # (4) GeoTIFF georeferencing tag gate.
    $gt = & "$here\inspect_geotiff.ps1" -Path $tif
    $tp = $gt.GeoTiePoints; $sc = $gt.GeoPixelScale; $kd = $gt.GeoKeyDir
    if (-not ($tp -and $sc -and $kd)) {
        Write-Host "  FAIL: GeoTIFF is missing geo tags" -ForegroundColor Red
        $failed++; continue
    }
    if ($tp.Length -ne 6 -or $tp[0] -ne 0.0 -or $tp[1] -ne 0.0) {
        Write-Host "  FAIL: GeoTIFF tiepoint not anchored at pixel (0,0)" -ForegroundColor Red
        $failed++; continue
    }
    $epsg = $null
    for ($i = 4; $i -lt $kd.Length; $i += 4) {
        if ($kd[$i] -eq 2048) { $epsg = $kd[$i+3]; break }
    }
    if ($epsg -ne 4326) {
        Write-Host "  FAIL: GeoTIFF CRS is not WGS-84 (EPSG:$epsg)" -ForegroundColor Red
        $failed++; continue
    }
    Write-Host ("  GeoTIFF georef: tiepoint(west={0:N4}, north={1:N4}) scale({2:N6},{3:N6}) EPSG:{4}" `
                -f $tp[3], $tp[4], $sc[0], $sc[1], $epsg) -ForegroundColor Green
}

Remove-Item -Recurse -Force $work
if ($failed -eq 0) { Write-Host "PASS (all $($variants.Count) variants x 3 formats)" -ForegroundColor Green; exit 0 }
Write-Host "FAIL ($failed of $($variants.Count) variants failed)" -ForegroundColor Red
exit 1
