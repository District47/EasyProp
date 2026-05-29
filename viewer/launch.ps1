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
    # Default to a per-user writable dir (NOT the current directory). The
    # cwd is unreliable -- if the user launches from a Start Menu PowerShell
    # shortcut, cwd is C:\Windows\system32, and any auto-fetch would silently
    # fail with permission-denied writing tile downloads.
    [string]$SourceDir  = "$env:LOCALAPPDATA\EasyProp\work-hd",
    [string]$SdfDir     = "",
    # Both binaries now ship out of one build tree at C:\splat-build (the older
    # C:\splat-build-hd path is kept as a fallback for users who haven't
    # reconfigured yet, but the unified tree is preferred so the Phase-12
    # OpenMP-parallelized splat-hd is picked up automatically).
    [string]$SplatHdExe = $(if (Test-Path 'C:\splat-build\Release\splat-hd.exe') {
                              'C:\splat-build\Release\splat-hd.exe'
                          } else {
                              'C:\splat-build-hd\Release\splat-hd.exe'
                          }),
    [string]$SrtmTool   = "C:\splat-build\utils\Release\srtm2sdf-hd.exe",
    # Cache dir for previously-computed (lat,lon,freq,power,gain,antenna_h,
    # range,pol) -> png+geo pairs. A cache hit serves the saved image in
    # ~100 ms instead of re-running the 2-minute splat. Files accumulate
    # forever -- you manage size by `Remove-Item $env:LOCALAPPDATA\EasyProp\
    # cache\*` if it grows too large (~15 MB per cached scenario).
    [string]$CacheDir   = "$env:LOCALAPPDATA\EasyProp\cache",
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
# Make sure $SourceDir exists; create it if it's the per-user default and
# the user has just run the script for the first time. Then Resolve-Path
# happily turns it into an absolute path.
if (-not (Test-Path $SourceDir)) {
    New-Item -ItemType Directory -Force -Path $SourceDir | Out-Null
}
$srcAbs = (Resolve-Path $SourceDir).Path
if ([string]::IsNullOrEmpty($SdfDir)) { $SdfDir = $srcAbs }
else {
    if (-not (Test-Path $SdfDir)) { New-Item -ItemType Directory -Force -Path $SdfDir | Out-Null }
    $SdfDir = (Resolve-Path $SdfDir).Path
}
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}
$CacheDir = (Resolve-Path $CacheDir).Path

# Sanity check: refuse to write into Windows / Program Files, even if the
# user explicitly pointed us there. Better to fail loudly here than to mask
# the error as a fake "404 from all mirrors" inside the fetcher.
foreach ($d in @($srcAbs, $SdfDir)) {
    if ($d -like 'C:\Windows*' -or $d -like 'C:\Program Files*' -or
        $d -like "${env:ProgramFiles(x86)}*") {
        Write-Host "FAIL: $d is a system directory; pick a writable folder for -SourceDir / -SdfDir." -ForegroundColor Red
        Write-Host "      Defaults to $env:LOCALAPPDATA\EasyProp\work-hd if you omit -SourceDir." -ForegroundColor Yellow
        exit 2
    }
}

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

function Get-EffectiveDegLimit {
    # Phase 13: shrink splat's analysis bbox to ~just-cover the user's
    # coverage radius (plus a small margin so the disc isn't clipped at
    # the rendered image edge). splat picks its bbox from the loaded SDF
    # pages, so feeding it a smaller tile set is how we make it compute
    # less. Returns the half-width in degrees.
    #
    # The 0.25-deg floor (~28 km) keeps very small ranges from collapsing
    # the bbox to a single tile (which under MAXPAGES=9 occasionally
    # confuses splat's edge-walk; cheap insurance vs. virtually no extra
    # compute at small ranges).
    param(
        [double]$RangeMi,
        [double]$MarginKm,
        [double]$HardCapDeg   # never exceed the launcher's -DegLimit
    )
    $rangeKm = $RangeMi * 1.609344
    $eff = ($rangeKm + $MarginKm) / 111.0
    if ($eff -lt 0.25)        { $eff = 0.25 }
    if ($eff -gt $HardCapDeg) { $eff = $HardCapDeg }
    return $eff
}

function Fetch-MissingTilesAsync {
    # Fetch each missing tile in parallel via Start-Job (one job per tile),
    # invoking the supplied $EmitEvent callback as tiles complete so the
    # caller can stream per-tile progress to the browser. Returns a hashtable
    # with counters {ok, skipped (404), failed}.
    #
    # Each job downloads from the AWS Mapzen Skadi mirror first (gzipped raw
    # hgt, comprehensive coastal coverage) then falls back to ESA SRTMGL1.
    # The conversion (srtm2sdf-hd) runs inside the same job, so parallelism
    # covers both download AND convert phases.
    param(
        [System.Collections.Generic.List[object]]$Tiles,
        [string]$OutDir,
        [string]$SrtmToolPath,
        [scriptblock]$EmitEvent
    )

    # Filter to tiles whose SDF doesn't already exist.
    $needed = @()
    foreach ($t in $Tiles) {
        $name = Get-SdfName -Lat $t.Lat -West $t.West
        if (-not (Test-Path (Join-Path $OutDir $name))) {
            $needed += $t
        }
    }
    $totalNeeded = $needed.Count
    & $EmitEvent @{
        stage         = 'fetch_start'
        tiles_total   = $Tiles.Count
        tiles_cached  = $Tiles.Count - $totalNeeded
        tiles_to_fetch= $totalNeeded
    }
    if ($totalNeeded -eq 0) {
        & $EmitEvent @{ stage='fetch_done'; tiles_fetched=0; tiles_skipped=0; tiles_failed=0 }
        return @{ ok=0; skipped=0; failed=0 }
    }

    # Per-tile worker scriptblock -- everything it needs must be passed in
    # (Start-Job runs in a separate PowerShell process; outer-scope vars are
    # NOT inherited).
    $worker = {
        param([int]$Lat, [int]$West, [string]$OutDir, [string]$SrtmTool)
        $tile   = 'N{0:D2}W{1:D3}' -f $Lat, $West
        $latPfx = 'N{0:D2}' -f $Lat
        $mirrors = @(
            @{ kind='gz';  url="https://s3.amazonaws.com/elevation-tiles-prod/skadi/$latPfx/$tile.hgt.gz" },
            @{ kind='zip'; url="https://step.esa.int/auxdata/dem/SRTMGL1/$tile.SRTMGL1.hgt.zip" }
        )
        $hgt = $null
        $mirrorTag = ''
        $lastStatus = 0
        $lastError = ''
        foreach ($m in $mirrors) {
            $tmp = Join-Path $OutDir ("$tile." + $(if ($m.kind -eq 'gz') {'hgt.gz'} else {'SRTMGL1.hgt.zip'}))
            try {
                Invoke-WebRequest -Uri $m.url -OutFile $tmp -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
            } catch {
                $lastError  = $_.Exception.Message
                $lastStatus = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
                continue
            }
            $hgtPath = Join-Path $OutDir "$tile.hgt"
            if ($m.kind -eq 'gz') {
                $inStream  = [System.IO.File]::OpenRead($tmp)
                $outStream = [System.IO.File]::Create($hgtPath)
                try {
                    $gz = [System.IO.Compression.GZipStream]::new($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                    $gz.CopyTo($outStream); $gz.Close()
                } finally { $outStream.Close(); $inStream.Close() }
                $hgt = $hgtPath
            } else {
                Expand-Archive -Path $tmp -DestinationPath $OutDir -Force
                $found = Get-ChildItem -Path $OutDir -Filter "$tile*.hgt" | Select-Object -First 1
                if ($found) { $hgt = $found.FullName }
            }
            Remove-Item $tmp -ErrorAction SilentlyContinue
            if ($hgt) { $mirrorTag = $m.kind; break }
        }

        if (-not $hgt) {
            if ($lastStatus -eq 404) {
                return [pscustomobject]@{ Tile=$tile; Lat=$Lat; West=$West; Status='skip'; Reason='404 from all mirrors (likely ocean)' }
            }
            return [pscustomobject]@{ Tile=$tile; Lat=$Lat; West=$West; Status='fail'; Reason=$lastError }
        }

        Push-Location $OutDir
        $exit = 0
        try {
            & $SrtmTool ([System.IO.Path]::GetFileName($hgt)) 2>&1 | Out-Null
            $exit = $LASTEXITCODE
        } finally { Pop-Location }
        Remove-Item $hgt -ErrorAction SilentlyContinue

        if ($exit -ne 0) {
            return [pscustomobject]@{ Tile=$tile; Lat=$Lat; West=$West; Status='fail'; Reason="srtm2sdf-hd exit $exit"; Mirror=$mirrorTag }
        }
        return [pscustomobject]@{ Tile=$tile; Lat=$Lat; West=$West; Status='ok'; Mirror=$mirrorTag }
    }

    # Spawn one parallel Start-Job per missing tile.
    $jobs = @()
    foreach ($t in $needed) {
        $jobs += Start-Job -ScriptBlock $worker -ArgumentList $t.Lat, $t.West, $OutDir, $SrtmToolPath
    }

    # Poll the job pool, emit progress events as individual tiles finish.
    $ok = 0; $skipped = 0; $failed = 0; $done = 0
    while ($jobs.Count -gt 0) {
        $finished = @($jobs | Where-Object { $_.State -in 'Completed','Failed','Stopped' })
        foreach ($j in $finished) {
            $result = Receive-Job $j 2>$null
            Remove-Job $j -Force
            $done++
            switch ($result.Status) {
                'ok'   { $ok++ }
                'skip' { $skipped++ }
                default{ $failed++ }
            }
            & $EmitEvent @{
                stage       = 'fetch_progress'
                tiles_done  = $done
                tiles_total = $totalNeeded
                tile        = $result.Tile
                status      = $result.Status
                mirror      = $result.Mirror
                reason      = $result.Reason
            }
        }
        $jobs = @($jobs | Where-Object { $_.State -notin 'Completed','Failed','Stopped' })
        if ($jobs.Count -gt 0) { Start-Sleep -Milliseconds 250 }
    }

    & $EmitEvent @{ stage='fetch_done'; tiles_fetched=$ok; tiles_skipped=$skipped; tiles_failed=$failed }
    return @{ ok=$ok; skipped=$skipped; failed=$failed }
}

function Parse-SplatProgress {
    # SPLAT! HD's stdout looks like:
    #
    #     Loading "X.sdf" into page 1... Done!
    #     Region "Y" assumed as sea-level into page 2... Done!
    #     ...
    #     Computing ITWOM signal power level contours of "LIVE"
    #     out to a radius of 48.28 kilometers with an RX antenna at 2.00 meters AGL...
    #
    #      0% to  25% .oOo.oOo.oOo.oOo. ...    <- 64 dots == 25% complete
    #     25% to  50% .oOo.oOo. ...
    #     50% to  75% ...
    #     75% to 100% ...
    #     Done!
    #
    #     Site analysis report written to: "LIVE-site_report.txt"
    #
    #     Writing "live.png" (10800x10800 png image)... Done!
    #
    # Map all that to a single (percent, phase) pair the browser can use to
    # drive its progress bar.
    param([string]$Text)
    if (-not $Text) {
        return [pscustomobject]@{ Phase='starting'; Percent=0 }
    }

    # If we've seen the final "Writing ... Done!" we're 100% done.
    if ($Text -match 'Writing\s+"[^"]+"[^\n]*\.\.\.\s+Done!\s*$') {
        return [pscustomobject]@{ Phase='done'; Percent=100 }
    }
    # If we're in the PNG-write phase but haven't finished yet.
    if ($Text -match 'Writing\s+"[^"]+"\s*\(([0-9x]+)') {
        return [pscustomobject]@{ Phase='writing_png'; Percent=95 }
    }

    # During compute: find the LAST progress line and count dots.
    $lines = $Text -split "`n"
    $last  = $null
    foreach ($l in $lines) {
        if ($l -match '^\s*(\d+)%\s+to\s+(\d+)%\s*(.*)$') { $last = $l }
    }
    if ($last -and ($last -match '^\s*(\d+)%\s+to\s+(\d+)%\s*(.*)$')) {
        $start  = [int]$Matches[1]
        $end    = [int]$Matches[2]
        $trail  = $Matches[3].TrimEnd()
        $dots   = [math]::Min(64, $trail.Length)
        $pct    = $start + ($dots / 64.0) * ($end - $start)
        # Reserve the last 5% for the PNG-write phase that follows.
        $pct    = [math]::Min(90, $pct * 0.9)
        return [pscustomobject]@{ Phase='computing'; Percent=[math]::Round($pct) }
    }

    if ($Text -match 'Computing ITWOM') {
        return [pscustomobject]@{ Phase='computing'; Percent=0 }
    }
    if ($Text -match 'Loading|Region') {
        return [pscustomobject]@{ Phase='loading_tiles'; Percent=0 }
    }
    return [pscustomobject]@{ Phase='starting'; Percent=0 }
}

# Bump this whenever splat-hd or the rendering logic changes in a way that
# would invalidate previously-cached PNGs. Cached files from a different
# schema simply won't be found by Get-CacheKey and the next run will
# regenerate. Stale files are inert -- delete the cache dir to clean them up.
$script:CACHE_SCHEMA = 'v2'   # v2: per-request tile-bbox tightening (Phase 13)

function Get-CacheKey {
    # Canonicalize the request into a stable JSON document, then SHA-256 it.
    # lat/lon round to ~11 m so that two clicks "at the same spot" hit cache.
    # 16 hex chars (64 bits) of hash is plenty for collision avoidance at the
    # scale of "user cache directory."
    param([pscustomobject]$Req)
    $canon = [pscustomobject]@{
        schema           = $script:CACHE_SCHEMA
        lat              = [math]::Round([double]$Req.lat,              4)
        lon              = [math]::Round([double]$Req.lon,              4)
        freq_mhz         = [math]::Round([double]$Req.freq_mhz,         3)
        watts            = [math]::Round([double]$Req.watts,            3)
        gain_dbi         = [math]::Round([double]$Req.gain_dbi,         2)
        antenna_height_m = [math]::Round([double]$Req.antenna_height_m, 2)
        range_mi         = [math]::Round([double]$Req.range_mi,         2)
        polarization     = "$($Req.polarization)"
    }
    $json = $canon | ConvertTo-Json -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $hex   = ($sha.ComputeHash($bytes) | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        return $hex.Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Test-CacheHit {
    param([string]$CacheDir, [string]$Key)
    $png = Join-Path $CacheDir "$Key.png"
    $geo = Join-Path $CacheDir "$Key.geo"
    return (Test-Path $png) -and (Test-Path $geo)
}

function Copy-CacheTo {
    # Cache hit: copy the previously-computed png+geo into the live.* slots
    # the browser polls.
    param([string]$CacheDir, [string]$Key, [string]$ServeDir)
    Copy-Item (Join-Path $CacheDir "$Key.png") (Join-Path $ServeDir 'live.png') -Force
    Copy-Item (Join-Path $CacheDir "$Key.geo") (Join-Path $ServeDir 'live.geo') -Force
}

function Save-Cache {
    # After a successful compute, archive the live.* outputs into the cache
    # so the next identical request becomes a hit.
    param([string]$CacheDir, [string]$Key, [string]$ServeDir, [pscustomobject]$Req)
    Copy-Item (Join-Path $ServeDir 'live.png') (Join-Path $CacheDir "$Key.png") -Force
    Copy-Item (Join-Path $ServeDir 'live.geo') (Join-Path $CacheDir "$Key.geo") -Force
    # Also write a small JSON sidecar so a human (or a future cleanup script)
    # can tell what each cached scenario actually was.
    $meta = [pscustomobject]@{
        schema    = $script:CACHE_SCHEMA
        key       = $Key
        cached_at = (Get-Date).ToString('o')
        request   = $Req
    }
    $meta | ConvertTo-Json -Depth 4 |
        Set-Content -Path (Join-Path $CacheDir "$Key.json") -Encoding utf8
}

function Invoke-SplatComputeStreaming {
    # End-to-end compute pipeline that emits progress events for the browser:
    #   1. setup        -- identifying required tiles
    #   2. fetch_start  -- announce how many tiles need fetching (rest cached)
    #   3. fetch_progress (xN, one per tile as it completes in parallel)
    #   4. fetch_done   -- fetch phase complete
    #   5. splat_start  -- splat-hd launched
    #   6. splat_progress (every ~1 sec while compute is running)
    #   7. done         -- png + geo ready for the browser to overlay
    #   8. error        -- on failure at any stage (terminates the stream)
    param([pscustomobject]$Req, [scriptblock]$EmitEvent)

    # -------- Cache check (first thing) -----------------------------------
    # Skip fetch + splat entirely for an identical previous request.
    $key = Get-CacheKey -Req $Req
    & $EmitEvent @{ stage='setup'; message='Checking cache'; cache_key=$key }
    if (Test-CacheHit -CacheDir $CacheDir -Key $key) {
        Copy-CacheTo -CacheDir $CacheDir -Key $key -ServeDir $serveDir
        & $EmitEvent @{
            stage          = 'done'
            png            = 'live.png'
            geo            = 'live.geo'
            elapsed_sec    = 0
            fetch_sec      = 0
            tiles_needed   = 0
            tiles_fetched  = 0
            tiles_skipped  = 0
            tiles_failed   = 0
            cached         = $true
            cache_key      = $key
        }
        return
    }

    # Phase 13: shrink splat's compute area to match the user's range,
    # instead of always rendering the full deg_limit (1.0-deg) bbox. We pass
    # the effective deg-limit to Get-RequiredTiles AND use it to stage a
    # per-request scratch dir with only those tiles; splat picks its bbox
    # from the SDF pages it finds.
    # Margin: how much breathing room beyond the user's coverage radius the
    # rendered image extends to. Smaller margin = tighter bbox = fewer SDF
    # tiles loaded = faster splat (often dramatically so when the TX is near
    # a tile boundary). 5 km keeps the coverage disc visibly inside the
    # image edge without spilling into neighbor tiles for most TXs.
    $effDeg = Get-EffectiveDegLimit -RangeMi $Req.range_mi -MarginKm 5.0 -HardCapDeg $DegLimit
    & $EmitEvent @{
        stage      = 'setup'
        message    = 'Identifying required SRTM tiles'
        cache_key  = $key
        eff_deg    = [math]::Round($effDeg, 3)
    }
    $required = Get-RequiredTiles -Lat $Req.lat -LonStd $Req.lon -RangeMi $Req.range_mi -DegLimit $effDeg

    # -------- Fetch phase (parallel) --------------------------------------
    $fetchSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $fetchTally = Fetch-MissingTilesAsync -Tiles $required -OutDir $SdfDir `
                          -SrtmToolPath $SrtmTool -EmitEvent $EmitEvent
    } catch {
        & $EmitEvent @{ stage='error'; error="SRTM fetch failed: $($_.Exception.Message)" }
        return
    }
    $fetchSw.Stop()

    # Phase 13: emit the effective bbox half-width for the browser log.
    # splat itself does the integer-tile snap; we just hand it the half-width
    # via -bbox so it bypasses the max_range/57 derivation that would
    # otherwise round up to extra tiles when the TX sits near a tile edge.
    & $EmitEvent @{
        stage      = 'bbox'
        message    = "Compute bbox half-width: $([math]::Round($effDeg, 3)) deg"
        eff_deg    = [math]::Round($effDeg, 3)
    }

    # -------- Write qth + lrp -------------------------------------------------
    $name = 'live'
    Write-Qth -Path (Join-Path $serveDir "$name.qth") `
              -Name 'LIVE' -Lat $Req.lat -LonStd $Req.lon `
              -HeightM $Req.antenna_height_m
    Write-Lrp -Path (Join-Path $serveDir "$name.lrp") `
              -FreqMhz $Req.freq_mhz -Watts $Req.watts `
              -GainDbi $Req.gain_dbi `
              -Polarization $Req.polarization

    foreach ($f in @('live.png','live.geo','LIVE-site_report.txt')) {
        $p = Join-Path $serveDir $f
        if (Test-Path $p) { Remove-Item $p -Force }
    }

    # -------- Splat phase (async with progress polling) ----------------------
    # See the inline comment in the previous Invoke-SplatCompute for the
    # rationale behind -L vs -c, -dbm, -R-in-km, etc. RX antenna is 2 m AGL.
    $rxHeightM = 2.0
    $rangeKm   = [math]::Round($Req.range_mi * 1.609344, 2)
    $stdout    = Join-Path $serveDir 'splat.stdout.txt'
    $stderr    = Join-Path $serveDir 'splat.stderr.txt'
    # Start-Process overwrites these files; no need to pre-create them, and
    # pre-creating them with Set-Content actually causes Start-Process to fail
    # to open them for redirection on some systems.

    & $EmitEvent @{ stage='splat_start'; message='Running ITWOM propagation' }
    $splatSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Phase 13: -bbox <eff_deg> tells splat-hd to use this half-width for
    # the analysis box instead of deriving one from -R. Coverage cutoff is
    # still set by -R; bbox is set independently by -bbox. Net effect: the
    # rendered image shrinks to ~(2*eff_deg)x(2*eff_deg) degrees and the
    # ray count drops proportionally.
    $argList = @('-d', $SdfDir, '-t', "$name.qth",
                 '-L', "$rxHeightM", '-R', "$rangeKm",
                 '-bbox', "$([math]::Round($effDeg, 4))",
                 '-dbm', '-metric', '-geo', '-o', "$name.png")
    $proc = Start-Process -FilePath $SplatHdExe -ArgumentList $argList `
              -WorkingDirectory $serveDir -NoNewWindow -PassThru `
              -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $lastPct = -1
    $lastPhase = ''
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 1000
        try {
            $text = [System.IO.File]::ReadAllText($stdout)
        } catch { $text = '' }
        $progress = Parse-SplatProgress $text
        if ($progress.Percent -ne $lastPct -or $progress.Phase -ne $lastPhase) {
            & $EmitEvent @{
                stage   = 'splat_progress'
                phase   = $progress.Phase
                percent = $progress.Percent
            }
            $lastPct   = $progress.Percent
            $lastPhase = $progress.Phase
        }
    }
    # WaitForExit() is required even after HasExited goes true -- without it,
    # the Process object's ExitCode property is unreliable when the process
    # was started via Start-Process -PassThru (often comes back $null, which
    # then fails `-ne 0` checks even on a successful run).
    $proc.WaitForExit()
    $exit = $proc.ExitCode
    $splatSw.Stop()

    # Treat live.png existence as the primary success signal. ExitCode is the
    # tiebreaker (e.g. splat might write a partial file then crash).
    $pngPath = Join-Path $serveDir 'live.png'
    if (-not (Test-Path $pngPath)) {
        $errText = ''
        if (Test-Path $stderr) {
            try { $errText = ((Get-Content $stderr -EA SilentlyContinue) -join "`n").Trim() } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($errText) -and (Test-Path $stdout)) {
            try { $errText = ((Get-Content $stdout -Tail 8 -EA SilentlyContinue) -join "`n").Trim() } catch {}
        }
        & $EmitEvent @{ stage='error'; error="splat-hd exit $exit (no output produced): $errText" }
        return
    }

    # Successful compute -- save into cache for next time.
    try {
        Save-Cache -CacheDir $CacheDir -Key $key -ServeDir $serveDir -Req $Req
    } catch {
        # Caching is best-effort; never fail the request just because we
        # couldn't write to the cache dir.
        Write-Host "  WARN: cache save failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    & $EmitEvent @{
        stage          = 'done'
        png            = 'live.png'
        geo            = 'live.geo'
        elapsed_sec    = [math]::Round($splatSw.Elapsed.TotalSeconds, 2)
        fetch_sec      = [math]::Round($fetchSw.Elapsed.TotalSeconds, 2)
        tiles_needed   = $required.Count
        tiles_fetched  = $fetchTally.ok
        tiles_skipped  = $fetchTally.skipped
        tiles_failed   = $fetchTally.failed
        cached         = $false
        cache_key      = $key
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
                # ---- /compute (streaming NDJSON) ----
                # The browser POSTs the form data and reads the response body
                # as a chunked stream of newline-delimited JSON events. Each
                # `setup`, `fetch_start`, `fetch_progress`, `splat_progress`,
                # `done` or `error` line is one chunk, flushed immediately, so
                # the progress bar can advance in real time.
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                Write-Host ("  [{0}] POST /compute  {1}" -f (Get-Date -Format 'HH:mm:ss'),
                            $body.Substring(0, [math]::Min(120, $body.Length))) -ForegroundColor Yellow

                $res.ContentType  = 'application/x-ndjson; charset=utf-8'
                $res.SendChunked  = $true

                # Closure-captures $res so the streaming compute can flush
                # one JSON line per event as it works.
                $emit = {
                    param([hashtable]$Event)
                    $line  = ($Event | ConvertTo-Json -Compress -Depth 6) + "`n"
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $res.OutputStream.Flush()
                    # Mirror key events to the server console so the operator
                    # can follow along too.
                    if ($Event.stage -in @('fetch_done','splat_start','done','error')) {
                        $ts = Get-Date -Format 'HH:mm:ss'
                        $col = if ($Event.stage -eq 'error') { 'Red' } elseif ($Event.stage -eq 'done') { 'Green' } else { 'DarkCyan' }
                        Write-Host ("  [{0}] {1}" -f $ts, ($Event | ConvertTo-Json -Compress -Depth 6)) -ForegroundColor $col
                    }
                }

                try {
                    $reqObj = $body | ConvertFrom-Json
                    Invoke-SplatComputeStreaming -Req $reqObj -EmitEvent $emit
                } catch {
                    # Best-effort: tell the browser even if the failure was
                    # before/during the stream.
                    try {
                        & $emit @{ stage='error'; error=$_.Exception.Message }
                    } catch { Write-Host "  ERROR (post-stream): $($_.Exception.Message)" -ForegroundColor Red }
                }

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
