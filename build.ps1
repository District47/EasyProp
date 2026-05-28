<#
.SYNOPSIS
    Configure and build SPLAT! on Windows with CMake + MSVC + vcpkg.

.DESCRIPTION
    Cross-platform replacement for the legacy interactive ./configure + ./build
    bash scripts. Dependencies (bzip2, zlib) come from vcpkg via the vcpkg.json
    manifest. Resolution mode and analysis-region size are CMake cache options
    (-DSPLAT_HD_MODE, -DSPLAT_MAXPAGES) instead of the old interactive prompts.

.PARAMETER Hd
    Build the high-definition (1 arc-second) variant -> splat-hd.exe.

.PARAMETER MaxPages
    Maximum analysis region in square degrees (perfect square: 1/4/9/16/25/36/49/64).

.PARAMETER Utils
    Also build the legacy companion utilities (srtm2sdf, usgs2sdf, ...).

.EXAMPLE
    ./build.ps1                       # standard mode, 3x3 deg region
    ./build.ps1 -Hd -MaxPages 4       # HD mode, 2x2 deg region
#>
param(
    [switch]$Hd,
    [ValidateSet(1,4,9,16,25,36,49,64)][int]$MaxPages = 9,
    [switch]$Utils,
    [string]$Config = "Release"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if (-not $env:VCPKG_ROOT) {
    if (Test-Path "$env:USERPROFILE\vcpkg\vcpkg.exe") {
        $env:VCPKG_ROOT = "$env:USERPROFILE\vcpkg"
    } else {
        throw "VCPKG_ROOT is not set and no vcpkg found at `$env:USERPROFILE\vcpkg. Bootstrap vcpkg first."
    }
}
Write-Host "Using VCPKG_ROOT = $($env:VCPKG_ROOT)"

$hdMode = if ($Hd) { 1 } else { 0 }
$buildUtils = if ($Utils) { "ON" } else { "OFF" }

cmake -S $root -B "$root\build" `
    -DSPLAT_HD_MODE=$hdMode `
    -DSPLAT_MAXPAGES=$MaxPages `
    -DSPLAT_BUILD_UTILS=$buildUtils
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed ($LASTEXITCODE)" }

cmake --build "$root\build" --config $Config
if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)" }

Write-Host "`nBuild succeeded. Binaries under: $root\build" -ForegroundColor Green
