<#
.SYNOPSIS
    Bulk-pre-fetch SRTM 1-arc-second terrain tiles into the EasyProp SDF cache.

.DESCRIPTION
    Pre-stages a region's worth of `.sdf` tiles so that subsequent /compute
    requests from the viewer land directly on cached terrain instead of pulling
    one tile at a time. Mirrors the per-tile worker from viewer/launch.ps1's
    Fetch-MissingTilesAsync (AWS Mapzen Skadi primary, ESA SRTMGL1 fallback,
    srtm2sdf-hd convert), but with a throttled job pool so 100+ tiles can run
    without spawning 100 simultaneous PowerShell processes.

    Already-converted tiles are skipped, so this script is resumable -- safe
    to Ctrl+C and rerun.

.PARAMETER Region
    Named preset bounding box. Currently supported:
        NE     -- Northeast US        (38..47 N, 68..81 W) ~140 grid cells
        MidAtl -- Mid-Atlantic        (36..42 N, 73..82 W) ~ 54 grid cells
        CONUS  -- Continental US      (24..49 N, 67..125 W) ~1,450 grid cells
    Use -MinLat/-MaxLat/-MinWest/-MaxWest for a custom box instead.

.PARAMETER MinLat
    Inclusive south edge (SW-corner latitude of the southernmost tile).

.PARAMETER MaxLat
    Inclusive north edge (SW-corner latitude of the northernmost tile).

.PARAMETER MinWest
    Inclusive east edge (SW-corner west-longitude of the easternmost tile).
    Tile N40W074 spans 74..73 W, so MinWest=68 includes tile N..W068 (68..67 W).

.PARAMETER MaxWest
    Inclusive west edge (SW-corner west-longitude of the westernmost tile).

.PARAMETER OutDir
    Where to drop the converted `.sdf` files. Defaults to the same dir the
    viewer uses, so a precache run directly populates the viewer's cache.

.PARAMETER MaxConcurrent
    Cap on simultaneous Start-Job workers. 8 is a reasonable default on a
    consumer connection -- mostly download-bound, srtm2sdf-hd convert is fast.

.PARAMETER SrtmTool
    Full path to srtm2sdf-hd.exe (the MSVC build output).

.EXAMPLE
    .\utils\precache_srtm.ps1 -Region NE

.EXAMPLE
    .\utils\precache_srtm.ps1 -MinLat 40 -MaxLat 41 -MinWest 74 -MaxWest 75
#>

[CmdletBinding(DefaultParameterSetName='Region')]
param(
    [Parameter(ParameterSetName='Region', Position=0)]
    [ValidateSet('NE','MidAtl','CONUS')]
    [string]$Region = 'NE',

    [Parameter(ParameterSetName='Custom', Mandatory=$true)]
    [int]$MinLat,
    [Parameter(ParameterSetName='Custom', Mandatory=$true)]
    [int]$MaxLat,
    [Parameter(ParameterSetName='Custom', Mandatory=$true)]
    [int]$MinWest,
    [Parameter(ParameterSetName='Custom', Mandatory=$true)]
    [int]$MaxWest,

    [string]$OutDir        = (Join-Path $env:LOCALAPPDATA 'EasyProp\work-hd'),
    [int]$MaxConcurrent    = 8,
    [string]$SrtmTool      = "C:\splat-build\utils\Release\srtm2sdf-hd.exe"
)

# ---- Resolve region preset ----------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Region') {
    switch ($Region) {
        'NE'     { $MinLat=38; $MaxLat=47; $MinWest=68; $MaxWest=81 }
        'MidAtl' { $MinLat=36; $MaxLat=41; $MinWest=73; $MaxWest=81 }
        'CONUS'  { $MinLat=24; $MaxLat=48; $MinWest=67; $MaxWest=124 }
    }
}

# ---- Sanity checks ------------------------------------------------------------
if (-not (Test-Path $SrtmTool)) {
    Write-Error "srtm2sdf-hd not found at: $SrtmTool"
    Write-Error "Build it first (cmake --build C:\splat-build --config Release) or pass -SrtmTool."
    exit 1
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# Refuse the same system paths launch.ps1 refuses.
$resolvedOut = (Resolve-Path $OutDir).Path
if ($resolvedOut -match '^C:\\Windows' -or $resolvedOut -match '^C:\\Program Files') {
    Write-Error "Refusing to write SDF into a system path: $resolvedOut"
    exit 1
}

# ---- Build the tile list ------------------------------------------------------
function Get-SdfName {
    # Matches utils/fetch_srtm.ps1 / viewer/launch.ps1 naming convention:
    # tile N<LAT>W<WEST> -> <LAT>_<LAT+1>_<WEST-1>_<WEST>-hd.sdf
    param([int]$Lat, [int]$West)
    '{0}_{1}_{2}_{3}-hd.sdf' -f $Lat, ($Lat+1), ($West-1), $West
}

$grid = New-Object 'System.Collections.Generic.List[object]'
for ($la = $MinLat; $la -le $MaxLat; $la++) {
    for ($w = $MinWest; $w -le $MaxWest; $w++) {
        $grid.Add([pscustomobject]@{ Lat=$la; West=$w })
    }
}

$needed = @()
$alreadyCached = 0
foreach ($t in $grid) {
    $sdf = Join-Path $OutDir (Get-SdfName -Lat $t.Lat -West $t.West)
    if (Test-Path $sdf) { $alreadyCached++ } else { $needed += $t }
}

Write-Host ""
Write-Host "==== EasyProp SRTM precache ====" -ForegroundColor Cyan
if ($PSCmdlet.ParameterSetName -eq 'Region') {
    Write-Host "Region        : $Region"
}
Write-Host "Bounding box  : $MinLat..$MaxLat N, $MinWest..$MaxWest W"
Write-Host "Grid          : $($grid.Count) cells"
Write-Host "Already cached: $alreadyCached"
Write-Host "To fetch      : $($needed.Count)"
Write-Host "Out dir       : $resolvedOut"
Write-Host "Parallelism   : $MaxConcurrent jobs"
Write-Host ""

if ($needed.Count -eq 0) {
    Write-Host "Nothing to do; region already fully cached." -ForegroundColor Green
    exit 0
}

# ---- Worker (same pattern as launch.ps1 Fetch-MissingTilesAsync) --------------
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
            Invoke-WebRequest -Uri $m.url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
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
            return [pscustomobject]@{ Tile=$tile; Status='skip'; Reason='404 (ocean)' }
        }
        return [pscustomobject]@{ Tile=$tile; Status='fail'; Reason=$lastError }
    }

    Push-Location $OutDir
    $exit = 0
    try {
        & $SrtmTool ([System.IO.Path]::GetFileName($hgt)) 2>&1 | Out-Null
        $exit = $LASTEXITCODE
    } finally { Pop-Location }
    Remove-Item $hgt -ErrorAction SilentlyContinue

    if ($exit -ne 0) {
        return [pscustomobject]@{ Tile=$tile; Status='fail'; Reason="srtm2sdf-hd exit $exit"; Mirror=$mirrorTag }
    }
    return [pscustomobject]@{ Tile=$tile; Status='ok'; Mirror=$mirrorTag }
}

# ---- Throttled job pool -------------------------------------------------------
$pending  = New-Object 'System.Collections.Generic.Queue[object]'
foreach ($t in $needed) { $pending.Enqueue($t) }

$total   = $needed.Count
$active  = @()
$ok = 0; $skipped = 0; $failed = 0; $done = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
    # Top up the pool to MaxConcurrent.
    while ($active.Count -lt $MaxConcurrent -and $pending.Count -gt 0) {
        $t = $pending.Dequeue()
        $active += Start-Job -ScriptBlock $worker -ArgumentList $t.Lat, $t.West, $OutDir, $SrtmTool
    }

    # Reap any that finished.
    $finished = @($active | Where-Object { $_.State -in 'Completed','Failed','Stopped' })
    foreach ($j in $finished) {
        $r = Receive-Job $j 2>$null
        Remove-Job $j -Force
        $done++
        $tag = ''
        switch ($r.Status) {
            'ok'   { $ok++;      $color='Green';  $tag = "ok ($($r.Mirror))" }
            'skip' { $skipped++; $color='DarkGray'; $tag = $r.Reason }
            default{ $failed++;  $color='Red';    $tag = "FAIL: $($r.Reason)" }
        }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        $rate    = if ($elapsed -gt 0) { $done / $elapsed } else { 0 }
        $remain  = $total - $done
        $etaSec  = if ($rate -gt 0) { [int]($remain / $rate) } else { 0 }
        $etaStr  = '{0:D2}:{1:D2}' -f ([int]($etaSec/60)), ($etaSec%60)
        Write-Host ("[{0,3}/{1,-3}] {2}  {3}   (ETA {4})" -f $done, $total, $r.Tile, $tag, $etaStr) -ForegroundColor $color
    }
    $active = @($active | Where-Object { $_.State -notin 'Completed','Failed','Stopped' })

    if ($active.Count -ge $MaxConcurrent -or ($pending.Count -eq 0 -and $active.Count -gt 0)) {
        Start-Sleep -Milliseconds 300
    }
}

$sw.Stop()

# Reconcile against disk state. The in-loop $ok/$skipped/$failed counters
# can under-count if Receive-Job races with Remove-Job in PS 5.1's job
# runspace -- the worker still finishes (and the SDF lands on disk), but
# we miss the reap. Walk the requested grid and count present .sdf files
# as the authoritative result.
$diskOk = 0
$diskMissing = 0
foreach ($t in $needed) {
    $sdf = Join-Path $OutDir (Get-SdfName -Lat $t.Lat -West $t.West)
    if (Test-Path $sdf) { $diskOk++ } else { $diskMissing++ }
}

Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Cyan
Write-Host ("Converted   : {0}  (loop counter saw {1})" -f $diskOk, $ok)
Write-Host ("Ocean/404   : {0}" -f $skipped)
Write-Host ("Missing     : {0}  (failed or 404)" -f $diskMissing)
Write-Host ("Elapsed     : {0:D2}:{1:D2}" -f ([int]($sw.Elapsed.TotalMinutes)), ($sw.Elapsed.Seconds))
Write-Host ("Cache dir   : {0}" -f $resolvedOut)
Write-Host ("Cache size  : {0:N1} MB" -f (((Get-ChildItem $OutDir -Filter '*-hd.sdf' | Measure-Object Length -Sum).Sum) / 1MB))
if ($diskMissing -gt 0) { exit 2 }
exit 0
