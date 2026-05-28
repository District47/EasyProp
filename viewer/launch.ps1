<#
.SYNOPSIS
    Launch SPLAT!'s interactive Leaflet viewer.

.DESCRIPTION
    Two-in-one HTTP server:
      * Static GETs for index.html + any PNG/GEO sidecar (so you can preview
        a pre-computed map by passing -BaseName).
      * A POST /compute endpoint that takes a JSON parameter blob, writes a
        live.qth + live.lrp into the serve dir, invokes splat-hd to produce
        live.png + live.geo, and reports back. The browser then re-fetches
        those files with a cache-buster and refreshes the overlay.

    The server runs on localhost via .NET HttpListener (no admin needed on
    localhost), single-threaded -- one compute at a time, which is fine for
    the one-user demo case.

.PARAMETER BaseName
    Name of an existing PNG+GEO pair (if any) to preload on first paint.
    Pass "wnju-real" to start with the real-terrain hero map. Default
    "live" works fine on first run -- the viewer just shows the basemap
    until you compute something.

.PARAMETER SourceDir
    Directory holding the existing .png/.geo (if any) AND where live.qth,
    live.lrp, live.png, live.geo will be written by compute requests.

.PARAMETER SdfDir
    Directory containing the SPLAT SDF tiles (defaults to -SourceDir).
    Must contain the *-hd.sdf files that cover wherever the TX gets placed.

.PARAMETER SplatHdExe
    Path to the HD splat binary (default: C:\splat-build-hd\Release\splat-hd.exe).

.PARAMETER Port
    Localhost port (default: 8765).

.PARAMETER NoBrowser
    Don't auto-open the default browser.
#>
param(
    [Parameter(Position=0)][string]$BaseName = "live",
    [string]$SourceDir  = ".",
    [string]$SdfDir     = "",
    [string]$SplatHdExe = "C:\splat-build-hd\Release\splat-hd.exe",
    [string]$SrtmTool   = "C:\splat-build\utils\Release\srtm2sdf-hd.exe",
    # deg_limit from splat.cpp main()'s switch(MAXPAGES). For an HD build
    # with MAXPAGES=9, splat caps its analysis half-width at 1.0 degrees
    # in both lat and lon, meaning it loads (and sea-level-fills) a 3x3
    # tile grid around any TX. Match that here so auto-fetch covers the
    # whole rendered image, not just the user's coverage radius.
    #   MAXPAGES = 1, 4, 9, 16, 25, 36, 49, 64
    #   deg_limit= 0.125, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5
    [double]$DegLimit = 1.0,
    [int]$Port = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$srcAbs = (Resolve-Path $SourceDir).Path
if ([string]::IsNullOrEmpty($SdfDir)) { $SdfDir = $srcAbs }
else { $SdfDir = (Resolve-Path $SdfDir).Path }

if (-not (Test-Path $SplatHdExe)) {
    Write-Host "FAIL: splat-hd.exe not found at $SplatHdExe" -ForegroundColor Red
    Write-Host "Build it with: cmake --build C:\splat-build-hd --config Release --target splat" -ForegroundColor Yellow
    exit 2
}

# Stage a serve dir that we control end-to-end. We copy the initial preview
# (if any) and the viewer HTML in, and splat-hd writes its outputs in here.
$serveDir = Join-Path $env:TEMP "splat_viewer_$([guid]::NewGuid().Guid.Substring(0,8))"
New-Item -ItemType Directory -Force -Path $serveDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'index.html') (Join-Path $serveDir 'index.html') -Force
foreach ($ext in @('png','geo')) {
    $src = Join-Path $srcAbs "$BaseName.$ext"
    if (Test-Path $src) { Copy-Item $src (Join-Path $serveDir "$BaseName.$ext") -Force }
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.png'  = 'image/png'
    '.tif'  = 'image/tiff'
    '.tiff' = 'image/tiff'
    '.geo'  = 'text/plain; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
}

# --------------------- helpers ---------------------------------------------

# Decimal degrees -> "D M S.s" string. Lat is "+ = N", lon (input convention)
# is "+ = E". SPLAT! .qth files want lat as "+ = N" too, but lon as "+ = W"
# (the legacy west-positive convention), so the caller flips lon's sign
# before passing it in.
function ConvertTo-Dms {
    param([double]$Decimal)
    $sign = if ($Decimal -lt 0) { '-' } else { '' }
    $abs  = [math]::Abs($Decimal)
    $d    = [int][math]::Floor($abs)
    $m    = [int][math]::Floor(($abs - $d) * 60)
    $s    = ($abs - $d) * 60 - $m
    $s    = [math]::Round($s * 60, 1)
    if ($s -ge 60) { $s -= 60; $m += 1 }
    if ($m -ge 60) { $m -= 60; $d += 1 }
    "{0}{1} {2} {3:F1}" -f $sign, $d, $m, $s
}

function Write-Qth {
    param($Path, $Name, [double]$Lat, [double]$LonStd, [double]$HeightM)
    # SPLAT! lon convention is "positive = West", standard is "positive = East".
    $latStr = ConvertTo-Dms $Lat
    $lonStr = ConvertTo-Dms (-1.0 * $LonStd)
    $body = @"
$Name
$latStr
$lonStr
$HeightM meters

"@
    [System.IO.File]::WriteAllText($Path, $body, [System.Text.UTF8Encoding]::new($false))
}

function Write-Lrp {
    param($Path, [double]$FreqMhz, [double]$Watts, [double]$GainDbi, [string]$Polarization)
    # ERP (relative to half-wave dipole) = Power * 10^((dBi - 2.15)/10).
    # That's the field SPLAT! actually consumes; the radio-card-style power
    # the form takes is converted here.
    $erp = $Watts * [math]::Pow(10.0, ($GainDbi - 2.15) / 10.0)
    $pol = if ($Polarization -eq 'H') { 0 } else { 1 }
    $body = @"
15.000     ; Earth Dielectric Constant (relative permittivity)
0.005      ; Earth Conductivity (Siemens/meter)
301.000    ; Atmospheric Bending Constant (N-units)
$($FreqMhz.ToString('F3'))  ; Frequency in MHz (20 MHz - 20 GHz)
5          ; Radio Climate (5 = Continental Temperate)
$pol       ; Polarization (0 = Horizontal, 1 = Vertical)
0.50       ; Fraction of situations
0.90       ; Fraction of time
$($erp.ToString('F2'))     ; ERP in Watts (from $Watts W TX + $GainDbi dBi antenna)
"@
    [System.IO.File]::WriteAllText($Path, $body, [System.Text.UTF8Encoding]::new($false))
}

function Get-RequiredTiles {
    # Returns the list of integer-degree HGT SW-corner pairs that SPLAT! HD
    # will iterate over when analyzing a TX at (Lat, LonStd).
    #
    # SPLAT! caps its analysis half-width at deg_limit (from MAXPAGES; see
    # the -DegLimit param above). The user's -c RangeMi only determines the
    # SHAPE of the coverage flood-fill -- the IMAGE that gets rendered always
    # spans (lat +/- deg_limit) x (lon +/- deg_limit), with any unloaded
    # tiles in that bbox sea-level-filled (the blue rectangle you'd
    # otherwise see). So we fetch the full deg_limit bbox.
    #
    # HGT naming: file N<LAT>W<WEST> covers latitudes [LAT, LAT+1] and west
    # longitudes [WEST-1, WEST]. The integer SW corners that intersect
    # [lat +/- deg, west +/- deg] are:
    #
    #     sw_lat in [floor(lat_min), floor(lat_max)]
    #     sw_w   in [floor(w_min)+1, floor(w_max)+1]
    #
    # (Slightly conservative on tile boundaries -- harmless: the fetcher's
    # already-cached check / 404 absorbs any extra.)
    #
    param([double]$Lat, [double]$LonStd, [double]$RangeMi, [double]$DegLimit)
    # Take the SMALLER of the user's coverage radius and splat's deg_limit;
    # splat itself does the same min() inside main().
    $degRange = $RangeMi / 69.0
    if ($degRange -gt $DegLimit) { $degRange = $DegLimit }
    # In practice deg_limit dominates for the typical small handheld ranges,
    # so we expand back to it so the rendered image isn't a blue rectangle
    # around real terrain near the TX.
    if ($degRange -lt $DegLimit) { $degRange = $DegLimit }
    $west = -1.0 * $LonStd

    $latLo = [int][math]::Floor($Lat  - $degRange)
    $latHi = [int][math]::Floor($Lat  + $degRange)
    $wLo   = [int][math]::Floor($west - $degRange) + 1
    $wHi   = [int][math]::Floor($west + $degRange) + 1

    $tiles = New-Object System.Collections.Generic.List[object]
    for ($la = $latLo; $la -le $latHi; $la++) {
        for ($w = $wLo; $w -le $wHi; $w++) {
            $tiles.Add([pscustomobject]@{ Lat=$la; West=$w })
        }
    }
    return $tiles
}

function Get-SdfName {
    # SDF naming matches utils/fetch_srtm.ps1: for HGT N<LAT>W<W> the file is
    # <LAT>_<LAT+1>_<W-1>_<W>-hd.sdf (min_north_max_north_min_west_max_west,
    # where min_west is the *east* edge of the tile in west-positive terms).
    param([int]$Lat, [int]$West)
    '{0}_{1}_{2}_{3}-hd.sdf' -f $Lat, ($Lat+1), ($West-1), $West
}

function Ensure-SrtmTiles {
    # Make sure every tile in the requested set has an *-hd.sdf in $SdfDir.
    # Missing ones get fetched + converted via utils/fetch_srtm.ps1, which
    # is itself idempotent (skips tiles whose .sdf already exists). Returns
    # the number of tiles that were actually freshly fetched.
    param([System.Collections.Generic.List[object]]$Tiles)
    $needed = @()
    foreach ($t in $Tiles) {
        $name = Get-SdfName -Lat $t.Lat -West $t.West
        if (-not (Test-Path (Join-Path $SdfDir $name))) {
            $needed += $t
        }
    }
    if ($needed.Count -eq 0) { return 0 }

    $minLat  = ($needed | Measure-Object -Property Lat  -Minimum).Minimum
    $maxLat  = ($needed | Measure-Object -Property Lat  -Maximum).Maximum
    $minWest = ($needed | Measure-Object -Property West -Minimum).Minimum
    $maxWest = ($needed | Measure-Object -Property West -Maximum).Maximum
    $fetcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'utils\fetch_srtm.ps1'

    & $fetcher -MinLat $minLat -MaxLat $maxLat -MinWest $minWest -MaxWest $maxWest `
               -OutDir $SdfDir -SrtmTool $SrtmTool | Out-Null

    # Count how many of the originally-missing tiles are now present.
    $fetched = 0
    foreach ($t in $needed) {
        if (Test-Path (Join-Path $SdfDir (Get-SdfName -Lat $t.Lat -West $t.West))) { $fetched++ }
    }
    return $fetched
}

function Invoke-SplatCompute {
    param([pscustomobject]$Req)
    $name = 'live'

    # 1. Auto-fetch any SRTM tiles the requested TX+range will need.
    $fetchSw = [System.Diagnostics.Stopwatch]::StartNew()
    $required = Get-RequiredTiles -Lat $Req.lat -LonStd $Req.lon -RangeMi $Req.range_mi -DegLimit $DegLimit
    $fetched  = 0
    try {
        $fetched = Ensure-SrtmTiles -Tiles $required
    } catch {
        return @{ ok=$false; error="SRTM fetch failed: $($_.Exception.Message)" }
    }
    $fetchSw.Stop()

    Write-Qth -Path (Join-Path $serveDir "$name.qth") `
              -Name 'LIVE' -Lat $Req.lat -LonStd $Req.lon `
              -HeightM $Req.antenna_height_m
    Write-Lrp -Path (Join-Path $serveDir "$name.lrp") `
              -FreqMhz $Req.freq_mhz -Watts $Req.watts `
              -GainDbi $Req.gain_dbi `
              -Polarization $Req.polarization

    # Remove the previous live output so a failed run doesn't leave stale
    # png/geo lying around for the browser to overlay.
    foreach ($f in @('live.png','live.geo','LIVE-site_report.txt')) {
        $p = Join-Path $serveDir $f
        if (Test-Path $p) { Remove-Item $p -Force }
    }

    $splatSw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = Join-Path $serveDir 'splat.stdout.txt'
    $stderr = Join-Path $serveDir 'splat.stderr.txt'
    $argList = @('-d', $SdfDir, '-t', "$name.qth", '-c', "$($Req.range_mi)",
                 '-metric', '-geo', '-o', "$name.png")
    $proc = Start-Process -FilePath $SplatHdExe -ArgumentList $argList `
              -WorkingDirectory $serveDir -NoNewWindow -Wait -PassThru `
              -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $splatSw.Stop()

    if ($proc.ExitCode -ne 0 -or -not (Test-Path (Join-Path $serveDir 'live.png'))) {
        $errText = ''
        if (Test-Path $stderr) { $errText = (Get-Content $stderr -Raw) }
        if ([string]::IsNullOrWhiteSpace($errText) -and (Test-Path $stdout)) {
            $errText = (Get-Content $stdout -Tail 8 -Raw)
        }
        return @{ ok=$false; error=("splat-hd exit " + $proc.ExitCode + ": " + $errText.Trim()) }
    }

    return @{
        ok            = $true
        png           = 'live.png'
        geo           = 'live.geo'
        elapsed_sec   = [math]::Round($splatSw.Elapsed.TotalSeconds, 2)
        fetch_sec     = [math]::Round($fetchSw.Elapsed.TotalSeconds, 2)
        tiles_needed  = $required.Count
        tiles_fetched = $fetched
    }
}

# --------------------- HTTP loop -------------------------------------------

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "FAIL: bind http://localhost:$Port/ -- $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$url = "http://localhost:$Port/?name=$BaseName"
Write-Host ""
Write-Host "  SPLAT! viewer up at $url" -ForegroundColor Cyan
Write-Host "  Serving $serveDir" -ForegroundColor DarkGray
Write-Host "  SDF tiles from $SdfDir" -ForegroundColor DarkGray
Write-Host "  splat-hd     $SplatHdExe" -ForegroundColor DarkGray
Write-Host "  Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        try {
            if ($req.HttpMethod -eq 'POST' -and $req.Url.LocalPath -eq '/compute') {
                # ---- /compute ----
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                Write-Host ("  [{0}] POST /compute  {1}" -f (Get-Date -Format 'HH:mm:ss'), $body.Substring(0, [math]::Min(120, $body.Length))) -ForegroundColor Yellow
                try {
                    $reqObj = $body | ConvertFrom-Json
                    $result = Invoke-SplatCompute -Req $reqObj
                } catch {
                    $result = @{ ok=$false; error=$_.Exception.Message }
                }
                $color = if ($result.ok) { 'Green' } else { 'Red' }
                Write-Host ("  [{0}] -> {1}" -f (Get-Date -Format 'HH:mm:ss'),
                            ($result | ConvertTo-Json -Compress)) -ForegroundColor $color
                $json = $result | ConvertTo-Json -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)

            } else {
                # ---- static GET ----
                $rel = [System.Uri]::UnescapeDataString($req.Url.LocalPath.TrimStart('/'))
                if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }
                if ($rel.Contains('..')) { $res.StatusCode = 403; $res.Close(); continue }
                $file = Join-Path $serveDir $rel
                if (Test-Path $file -PathType Leaf) {
                    $ext = [System.IO.Path]::GetExtension($file).ToLower()
                    $res.ContentType = $mime[$ext]
                    if (-not $res.ContentType) { $res.ContentType = 'application/octet-stream' }
                    $data = [System.IO.File]::ReadAllBytes($file)
                    $res.ContentLength64 = $data.Length
                    $res.OutputStream.Write($data, 0, $data.Length)
                } else {
                    $res.StatusCode = 404
                    $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found: $rel")
                    $res.OutputStream.Write($msg, 0, $msg.Length)
                }
            }
        } catch {
            try { $res.StatusCode = 500 } catch {}
            try {
                $msg = [System.Text.Encoding]::UTF8.GetBytes("Server error: $($_.Exception.Message)")
                $res.OutputStream.Write($msg, 0, $msg.Length)
            } catch {}
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            $res.Close()
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
    Remove-Item -Recurse -Force $serveDir -ErrorAction SilentlyContinue
}
