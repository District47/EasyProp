<#
.SYNOPSIS
    Generate a synthetic SPLAT! Data File (SDF) tile for regression testing.

.DESCRIPTION
    Emits a 1200x1200 standard-resolution SDF tile of uniform terrain (default
    50 m). The file is 5.76 MB and intentionally not committed to the repo --
    regenerate on demand. Format per src/splat.cpp (LoadSDF_SDF):
        line 1: max west longitude
        line 2: min north latitude
        line 3: min west longitude
        line 4: max north latitude
        then 1,440,000 elevation integers (one per line), each in meters.

    Default tile covers 40-41N x 74-75W (the WNJU-DT sample area, named
    "40_41_74_75.sdf" on Windows -- the '_' replaces the upstream ':' which
    NTFS reserves for alternate data streams).

.EXAMPLE
    .\gen_synthetic_sdf.ps1 -OutDir C:\splat-build\work
#>
param(
    [string]$OutDir   = ".",
    [int]$MinNorth    = 40,
    [int]$MaxNorth    = 41,
    [int]$MinWest     = 74,
    [int]$MaxWest     = 75,
    [int]$ElevMeters  = 50
)

$ErrorActionPreference = 'Stop'
$sep = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { '_' } else { ':' }
$name = "{0}{1}{2}{1}{3}{1}{4}.sdf" -f $MinNorth, $sep, $MaxNorth, $MinWest, $MaxWest
$path = Join-Path $OutDir $name

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$sw = [System.IO.StreamWriter]::new($path, $false, [System.Text.Encoding]::ASCII)
$sw.WriteLine($MaxWest)
$sw.WriteLine($MinNorth)
$sw.WriteLine($MinWest)
$sw.WriteLine($MaxNorth)
$line = "$ElevMeters"
for ($i = 0; $i -lt 1440000; $i++) { $sw.WriteLine($line) }
$sw.Close()

"Wrote $path ($((Get-Item $path).Length) bytes, uniform ${ElevMeters}m)"
