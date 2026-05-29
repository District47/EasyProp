<#
.SYNOPSIS
    Stage a self-contained EasyProp release zip from the local build tree.

.DESCRIPTION
    Walks the MSVC build outputs at C:\splat-build, gathers every binary +
    its vcpkg-built DLLs + the four MSVC runtime DLLs (msvcp140, vcruntime140,
    vcruntime140_1, vcomp140) so the zip runs on a stock Windows 10 / 11 box
    with no Visual C++ Redistributable install required. Bundles viewer/,
    utils/*.ps1, a README, and a top-level EasyProp.bat double-click launcher.

    No precache tiles are included -- users download the ~30 MB zip and either
    let auto-fetch populate tiles per click, or run the bundled
    utils\precache_srtm.ps1 -Region NE for a one-shot ~6 GB pre-stage.

.PARAMETER Version
    Version string, e.g. "0.1.0". Goes into the zip filename and README.

.PARAMETER StageDir
    Where to assemble the contents. Defaults to %TEMP%\EasyProp-<Version>.

.PARAMETER OutZip
    Where to write the final zip. Defaults to alongside this script.

.PARAMETER BuildDir
    The CMake build dir (default C:\splat-build).

.PARAMETER VsRedist
    Folder under the VS Build Tools redist tree to source MSVC runtime DLLs
    from. Auto-detected if omitted.
#>
[CmdletBinding()]
param(
    [string]$Version  = '0.1.0',
    [string]$StageDir = '',
    [string]$OutZip   = '',
    [string]$BuildDir = 'C:\splat-build',
    [string]$VsRedist = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if ([string]::IsNullOrEmpty($StageDir)) {
    $StageDir = Join-Path $env:TEMP "EasyProp-$Version"
}
if ([string]::IsNullOrEmpty($OutZip)) {
    $OutZip = Join-Path $repo "EasyProp-win-x64-$Version.zip"
}

Write-Host "==== EasyProp release builder ====" -ForegroundColor Cyan
Write-Host "Version  : $Version"
Write-Host "BuildDir : $BuildDir"
Write-Host "Stage    : $StageDir"
Write-Host "Output   : $OutZip"

# ---- Locate MSVC runtime + OpenMP DLLs -------------------------------------
if ([string]::IsNullOrEmpty($VsRedist)) {
    foreach ($p in @(
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC',
        'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC')) {
        if (Test-Path $p) { $VsRedist = $p; break }
    }
}
if (-not (Test-Path $VsRedist)) {
    Write-Error "VS Build Tools redist dir not found. Pass -VsRedist explicitly."
    exit 1
}
$wantRuntime = @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','vcomp140.dll')
$runtimeMap  = @{}
foreach ($f in Get-ChildItem $VsRedist -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue) {
    if ($f.Directory.FullName -match 'x64\\Microsoft\.VC14[34]\.(CRT|OpenMP)') {
        $n = $f.Name.ToLower()
        if ($wantRuntime -contains $n -and -not $runtimeMap.ContainsKey($n)) {
            $runtimeMap[$n] = $f.FullName
        }
    }
}
$missing = @($wantRuntime | Where-Object { -not $runtimeMap.ContainsKey($_) })
if ($missing.Count -gt 0) {
    Write-Error "Missing required runtime DLLs: $($missing -join ', ') under $VsRedist"
    exit 1
}

# ---- Reset stage ------------------------------------------------------------
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Path $StageDir | Out-Null
$bin = Join-Path $StageDir 'bin'
New-Item -ItemType Directory -Path $bin | Out-Null

# ---- Copy binaries ----------------------------------------------------------
$binaries = @(
    "$BuildDir\Release\splat.exe",
    "$BuildDir\Release\splat-hd.exe",
    "$BuildDir\utils\Release\sdf_hd_to_std.exe",
    "$BuildDir\utils\Release\srtm2sdf.exe",
    "$BuildDir\utils\Release\srtm2sdf-hd.exe"
)
foreach ($b in $binaries) {
    if (-not (Test-Path $b)) { Write-Error "Missing build output: $b"; exit 1 }
    Copy-Item $b $bin
    Write-Host "  + bin\$(Split-Path $b -Leaf)" -ForegroundColor Green
}

# ---- Copy vcpkg DLLs from the binaries' own dir (CMake copied them there) -
foreach ($d in Get-ChildItem "$BuildDir\Release" -Filter '*.dll' -ErrorAction SilentlyContinue) {
    Copy-Item $d.FullName $bin
    Write-Host "  + bin\$($d.Name) (vcpkg)" -ForegroundColor Green
}

# ---- Copy MSVC runtime DLLs ------------------------------------------------
foreach ($n in $wantRuntime) {
    Copy-Item $runtimeMap[$n] $bin
    Write-Host "  + bin\$n (MSVC redist)" -ForegroundColor Green
}

# ---- Copy viewer + utility scripts ----------------------------------------
$viewerOut = Join-Path $StageDir 'viewer'
New-Item -ItemType Directory -Path $viewerOut | Out-Null
Copy-Item (Join-Path $repo 'viewer\index.html') $viewerOut
Copy-Item (Join-Path $repo 'viewer\launch.ps1') $viewerOut
Write-Host "  + viewer\index.html" -ForegroundColor Green
Write-Host "  + viewer\launch.ps1" -ForegroundColor Green

$utilsOut = Join-Path $StageDir 'utils'
New-Item -ItemType Directory -Path $utilsOut | Out-Null
foreach ($s in 'precache_srtm.ps1','downsample_hd_to_std.ps1','fetch_srtm.ps1') {
    $src = Join-Path $repo "utils\$s"
    if (Test-Path $src) {
        Copy-Item $src $utilsOut
        Write-Host "  + utils\$s" -ForegroundColor Green
    }
}

# ---- Launcher .bat (double-click to start) --------------------------------
$bat = @'
@echo off
rem -------------------------------------------------------------------
rem  EasyProp launcher -- starts the viewer on http://localhost:8765
rem -------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
rem strip trailing backslash
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
echo Starting EasyProp viewer...
echo App dir: %HERE%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%\viewer\launch.ps1" ^
    -SplatHdExe   "%HERE%\bin\splat-hd.exe" ^
    -SplatStdExe  "%HERE%\bin\splat.exe" ^
    -SrtmTool     "%HERE%\bin\srtm2sdf-hd.exe"
pause
'@
$bat | Set-Content -Path (Join-Path $StageDir 'EasyProp.bat') -Encoding ASCII
Write-Host "  + EasyProp.bat" -ForegroundColor Green

# ---- README ---------------------------------------------------------------
$readme = @"
================================================================
 EasyProp $Version  --  Click-anywhere RF coverage viewer
================================================================

Built on SPLAT! 1.4.2 + ITWOM, ported to Windows / MSVC.

Quick start
-----------
1. Unzip anywhere (e.g. C:\EasyProp).
2. Double-click EasyProp.bat. A PowerShell window opens; the viewer
   pops up at http://localhost:8765 in your default browser.
3. Click "Click map to set TX", pick a spot, set band/power/range,
   hit "Compute coverage". First click in a region takes 30-60 s to
   auto-fetch the SRTM terrain; subsequent clicks reuse the cache.

System requirements
-------------------
- Windows 10 / 11, 64-bit.
- ~4 GB RAM free for splat-hd; ~1 GB free for draft mode.
- Internet on first use (SRTM tile download from AWS).
- No Visual C++ Redistributable install needed -- the four MSVC
  runtime DLLs (msvcp140, vcruntime140, vcruntime140_1, vcomp140)
  are bundled in bin\.

Modes
-----
- HD (default): 1-arc-second, ~85 s / click, sharp coverage edges.
- Draft (checkbox in viewer): 3-arc-second, ~5 s / click, chunkier
  edges. Requires downsampled tiles -- run utils\downsample_hd_to_std.ps1
  AFTER you've cached HD tiles for the region.

Pre-cache a region (optional but recommended)
---------------------------------------------
Auto-fetch on click works fine, but pre-caching makes the first
click in any new region instant. From a PowerShell prompt in the
unzipped folder:

    .\utils\precache_srtm.ps1 -Region NE
    .\utils\downsample_hd_to_std.ps1   # then if you want Draft mode

Built-in regions: NE (~140 tiles / ~6 GB), MidAtl (~54 / ~2 GB),
CONUS (~1,450 / ~50 GB). Custom box via
-MinLat / -MaxLat / -MinWest / -MaxWest.

Cache locations
---------------
- HD SDF tiles  : %LOCALAPPDATA%\EasyProp\work-hd  (~30 MB/tile)
- Draft tiles    : %LOCALAPPDATA%\EasyProp\work-std (~6 MB/tile)
- Computed PNGs : %LOCALAPPDATA%\EasyProp\cache    (~1-15 MB/result)

To wipe a cache: just delete that folder.

Bundled binaries
----------------
bin\splat.exe          standard splat (3-arc-sec, Draft mode)
bin\splat-hd.exe       HD splat (1-arc-sec, default)
bin\srtm2sdf.exe       HGT -> standard SDF
bin\srtm2sdf-hd.exe    HGT -> HD SDF
bin\sdf_hd_to_std.exe  Phase-14 HD-SDF -> standard-SDF downsampler

Project: https://github.com/District47/EasyProp
"@
$readme | Set-Content -Path (Join-Path $StageDir 'README.txt') -Encoding ASCII
Write-Host "  + README.txt" -ForegroundColor Green

# ---- Zip --------------------------------------------------------------------
if (Test-Path $OutZip) { Remove-Item $OutZip -Force }
Write-Host ""
Write-Host "Compressing -> $OutZip ..." -ForegroundColor Yellow
Compress-Archive -Path "$StageDir\*" -DestinationPath $OutZip -CompressionLevel Optimal

$zip = Get-Item $OutZip
Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Cyan
Write-Host ("Stage    : {0} ({1:N1} MB)" -f $StageDir, ((Get-ChildItem $StageDir -Recurse | Measure-Object Length -Sum).Sum / 1MB))
Write-Host ("Zip      : {0} ({1:N1} MB)" -f $OutZip, ($zip.Length / 1MB))
Write-Host ""
Write-Host "Smoke-test the zip:" -ForegroundColor Yellow
Write-Host "  1. Copy to a fresh dir, e.g. C:\TestEasyProp\"
Write-Host "  2. Expand-Archive '$OutZip' -DestinationPath 'C:\TestEasyProp\'"
Write-Host "  3. Run C:\TestEasyProp\EasyProp.bat"
