<#
.SYNOPSIS
    Download SRTM 1-arc-second elevation tiles for a bounding box, unzip them,
    and convert each into SPLAT! HD SDF format (`<lat>_<lat+1>_<west>_<west+1>-hd.sdf`).

.DESCRIPTION
    Pulls each 1°x1° tile that touches the requested box, unpacks it, and
    runs srtm2sdf-hd to convert into a SPLAT-ready SDF.

    Mirrors tried in order:
      1. Mapzen/Amazon Skadi (https://s3.amazonaws.com/elevation-tiles-prod/
         skadi/<NN>/<tile>.hgt.gz, public S3, gzip-compressed raw hgt).
         More complete: includes coastal tiles ESA omits.
      2. ESA SRTMGL1     (https://step.esa.int/auxdata/dem/SRTMGL1/<tile>.SRTMGL1.hgt.zip,
         zip-compressed, missing some coastal tiles).

    Tile naming follows the upstream "SW corner" convention: SRTM file
    N40W074.hgt covers latitudes 40-41N and longitudes -74 to -73 (= west
    73-74). Pass the SW corners you want covered as integer-degree pairs.

    Tiles over ocean (no land mass in SRTM) 404 from ESA; the script reports
    them and continues, so a bbox can safely include ocean.

.PARAMETER MinLat
    Smallest northern latitude of the SW-corner range (e.g. 40 for tile N40*).

.PARAMETER MaxLat
    Largest northern latitude of the SW-corner range (inclusive).

.PARAMETER MinWest
    Smallest west longitude of the SW-corner range, positive integer
    (e.g. 74 means longitude -74 = 74 W).

.PARAMETER MaxWest
    Largest west longitude of the SW-corner range (inclusive).

.PARAMETER OutDir
    Where to write the .sdf files (default: current directory).

.PARAMETER SrtmTool
    Path to the built srtm2sdf-hd.exe.

.PARAMETER KeepHgt
    Keep the unzipped raw .hgt files after conversion (default: delete).

.EXAMPLE
    # Covers the 4 tiles WNJU-DT's 30-mile coverage needs:
    fetch_srtm.ps1 -MinLat 40 -MaxLat 41 -MinWest 74 -MaxWest 75 -OutDir C:\splat-work
#>
param(
    [Parameter(Mandatory)][int]$MinLat,
    [Parameter(Mandatory)][int]$MaxLat,
    [Parameter(Mandatory)][int]$MinWest,
    [Parameter(Mandatory)][int]$MaxWest,
    [string]$OutDir   = ".",
    [string]$SrtmTool = "C:\splat-build\utils\Release\srtm2sdf-hd.exe",
    [switch]$KeepHgt
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $SrtmTool)) {
    Write-Host "FAIL: srtm2sdf-hd not found at $SrtmTool" -ForegroundColor Red
    Write-Host "Build it with: cmake --build C:\splat-build --config Release --target srtm2sdf-hd" -ForegroundColor Yellow
    exit 2
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

function Get-MirrorUrls {
    param([string]$Tile, [string]$LatPrefix)
    @(
        # Mapzen/Amazon Skadi -- public S3, gzipped raw hgt, more complete.
        @{ kind='gz';  url="https://s3.amazonaws.com/elevation-tiles-prod/skadi/$LatPrefix/$Tile.hgt.gz" },
        # ESA SRTMGL1 fallback -- zipped, missing some coastal tiles.
        @{ kind='zip'; url="https://step.esa.int/auxdata/dem/SRTMGL1/$Tile.SRTMGL1.hgt.zip" }
    )
}

function Expand-Hgt {
    # Decompress $src ($kind = 'gz' or 'zip') into $OutDir as <Tile>.hgt.
    # Returns the path to the extracted .hgt or $null on failure.
    param([string]$Src, [string]$Kind, [string]$Tile, [string]$OutDir)
    $hgtPath = Join-Path $OutDir "$Tile.hgt"
    if ($Kind -eq 'gz') {
        $inStream  = [System.IO.File]::OpenRead($Src)
        $outStream = [System.IO.File]::Create($hgtPath)
        try {
            $gz = [System.IO.Compression.GZipStream]::new($inStream, [System.IO.Compression.CompressionMode]::Decompress)
            $gz.CopyTo($outStream)
            $gz.Close()
        } finally {
            $outStream.Close(); $inStream.Close()
        }
        return $hgtPath
    }
    # zip
    Expand-Archive -Path $Src -DestinationPath $OutDir -Force
    $found = Get-ChildItem -Path $OutDir -Filter "$Tile*.hgt" | Select-Object -First 1
    return $(if ($found) { $found.FullName } else { $null })
}

$ok = 0; $skipped = 0; $failed = 0

for ($lat = $MinLat; $lat -le $MaxLat; $lat++) {
    for ($lon = $MinWest; $lon -le $MaxWest; $lon++) {
        $tile   = 'N{0:D2}W{1:D3}' -f $lat, $lon
        $latPfx = 'N{0:D2}' -f $lat
        $sdf  = Join-Path $OutDir ('{0}_{1}_{2}_{3}-hd.sdf' -f $lat, ($lat+1), ($lon-1), $lon)
        if (Test-Path $sdf) {
            Write-Host ("  {0,-8} -> already converted ({1})" -f $tile, (Split-Path -Leaf $sdf)) -ForegroundColor DarkGray
            $ok++; continue
        }

        # Try each mirror in turn; first success wins.
        $hgt = $null
        $mirrorTag = ''
        foreach ($m in Get-MirrorUrls -Tile $tile -LatPrefix $latPfx) {
            $tmp = Join-Path $OutDir "$tile.$(if ($m.kind -eq 'gz') {'hgt.gz'} else {'SRTMGL1.hgt.zip'})"
            try {
                Invoke-WebRequest -Uri $m.url -OutFile $tmp -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            } catch {
                continue
            }
            $hgt = Expand-Hgt -Src $tmp -Kind $m.kind -Tile $tile -OutDir $OutDir
            Remove-Item $tmp -ErrorAction SilentlyContinue
            if ($hgt) { $mirrorTag = "($($m.kind))"; break }
        }

        Write-Host ("  {0,-8} fetch  " -f $tile) -NoNewline
        if (-not $hgt) {
            Write-Host "404 from all mirrors (likely ocean), skipping" -ForegroundColor DarkYellow
            $skipped++
            continue
        }

        Write-Host "$mirrorTag convert  " -NoNewline
        Push-Location $OutDir
        try {
            & $SrtmTool ([System.IO.Path]::GetFileName($hgt)) 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "FAIL (exit $LASTEXITCODE)" -ForegroundColor Red
                $failed++; continue
            }
        } finally { Pop-Location }

        if (-not $KeepHgt) { Remove-Item $hgt -ErrorAction SilentlyContinue }
        Write-Host "ok -> $(Split-Path -Leaf $sdf)" -ForegroundColor Green
        $ok++
    }
}

Write-Host ""
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("Done. {0} ready, {1} ocean-skipped, {2} failed." -f $ok, $skipped, $failed) -ForegroundColor $color
if ($failed -gt 0) { exit 1 } else { exit 0 }
