<#
.SYNOPSIS
    Bulk-downsample every HD .sdf in -HdDir to a standard .sdf in -StdDir.

.DESCRIPTION
    Walks every <lat>_<lat+1>_<w-1>_<w>-hd.sdf and emits the equivalent
    <lat>_<lat+1>_<w-1>_<w>.sdf at 1/3 the resolution, by 3x3 averaging
    of HD elevation samples. Output is the same on-disk format standard
    splat (no -hd suffix) consumes, so the Phase-14 Draft toggle in the
    viewer Just Works without re-downloading any .hgt files.

    Throttled-parallel via Start-Job; idempotent (skips outputs that
    already exist).

.PARAMETER HdDir
    Directory containing *-hd.sdf inputs. Defaults to the viewer's HD
    cache dir.

.PARAMETER StdDir
    Where to write the *.sdf outputs. Created if missing.

.PARAMETER MaxConcurrent
    Cap on simultaneous downsamples. The work is RAM-bound (HD samples
    are buffered in memory: 25 MB per worker) and CPU-bound by atoi on
    text data, so a small fan-out (4-8) saturates the box.

.PARAMETER Tool
    Path to sdf_hd_to_std.exe.

.EXAMPLE
    .\utils\downsample_hd_to_std.ps1
#>
[CmdletBinding()]
param(
    [string]$HdDir         = (Join-Path $env:LOCALAPPDATA 'EasyProp\work-hd'),
    [string]$StdDir        = (Join-Path $env:LOCALAPPDATA 'EasyProp\work-std'),
    [int]$MaxConcurrent    = 4,
    [string]$Tool          = 'C:\splat-build\utils\Release\sdf_hd_to_std.exe'
)

if (-not (Test-Path $Tool)) {
    Write-Error "Downsampler not found at: $Tool"
    Write-Error "Build it: cmake --build C:\splat-build --config Release --target sdf_hd_to_std"
    exit 1
}
if (-not (Test-Path $HdDir)) { Write-Error "HdDir not found: $HdDir"; exit 1 }
New-Item -ItemType Directory -Path $StdDir -Force | Out-Null

$hdTiles = Get-ChildItem $HdDir -Filter '*-hd.sdf'
$needed = @()
$cached = 0
foreach ($t in $hdTiles) {
    $std = $t.Name -replace '-hd\.sdf$', '.sdf'
    if (Test-Path (Join-Path $StdDir $std)) { $cached++ } else { $needed += $t }
}

Write-Host ""
Write-Host "==== EasyProp HD-to-STD downsample ====" -ForegroundColor Cyan
Write-Host "HD dir         : $HdDir ($($hdTiles.Count) tiles)"
Write-Host "STD dir        : $StdDir"
Write-Host "Already STD    : $cached"
Write-Host "To downsample  : $($needed.Count)"
Write-Host "Parallelism    : $MaxConcurrent jobs"
Write-Host ""

if ($needed.Count -eq 0) { Write-Host 'Nothing to do.' -ForegroundColor Green; exit 0 }

$worker = {
    param([string]$Src, [string]$Dst, [string]$Tool)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Tool $Src $Dst | Out-Null
    $sw.Stop()
    [pscustomobject]@{
        Tile    = [System.IO.Path]::GetFileName($Src)
        Sec     = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Ok      = ($LASTEXITCODE -eq 0) -and (Test-Path $Dst)
        SizeMb  = if (Test-Path $Dst) { [math]::Round((Get-Item $Dst).Length / 1MB, 2) } else { 0 }
    }
}

$pending = New-Object 'System.Collections.Generic.Queue[object]'
foreach ($t in $needed) {
    $pending.Enqueue(@{
        Src = $t.FullName
        Dst = Join-Path $StdDir ($t.Name -replace '-hd\.sdf$', '.sdf')
    })
}
$active = @()
$done = 0; $ok = 0; $failed = 0; $totalSec = 0.0
$total = $needed.Count
$wall = [System.Diagnostics.Stopwatch]::StartNew()

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
    while ($active.Count -lt $MaxConcurrent -and $pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $active += Start-Job -ScriptBlock $worker -ArgumentList $item.Src, $item.Dst, $Tool
    }
    $finished = @($active | Where-Object { $_.State -in 'Completed','Failed','Stopped' })
    foreach ($j in $finished) {
        $r = Receive-Job $j 2>$null
        Remove-Job $j -Force
        $done++
        if ($r.Ok) { $ok++; $totalSec += $r.Sec } else { $failed++ }
        $color = if ($r.Ok) { 'Green' } else { 'Red' }
        $tag   = if ($r.Ok) { "ok ($($r.SizeMb) MB, $($r.Sec)s)" } else { 'FAIL' }
        Write-Host ("[{0,3}/{1,-3}] {2}  {3}" -f $done, $total, $r.Tile, $tag) -ForegroundColor $color
    }
    $active = @($active | Where-Object { $_.State -notin 'Completed','Failed','Stopped' })
    if ($active.Count -ge $MaxConcurrent -or ($pending.Count -eq 0 -and $active.Count -gt 0)) {
        Start-Sleep -Milliseconds 200
    }
}
$wall.Stop()

# Disk-truth reconcile, same idea as precache_srtm.ps1.
$diskOk = (Get-ChildItem $StdDir -Filter '*.sdf' | Where-Object { $_.Name -notmatch '-hd\.sdf$' }).Count
Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Cyan
Write-Host ("Downsampled : {0}  (disk: {1})" -f $ok, $diskOk)
Write-Host ("Failed      : {0}" -f $failed)
Write-Host ("Wall time   : {0:N1} s" -f $wall.Elapsed.TotalSeconds)
Write-Host ("Cache dir   : {0}" -f $StdDir)
$totalMb = (Get-ChildItem $StdDir -Filter '*.sdf' | Where-Object { $_.Name -notmatch '-hd\.sdf$' } |
            Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Total size  : {0:N1} MB" -f $totalMb)
if ($failed -gt 0) { exit 2 } else { exit 0 }
