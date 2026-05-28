<#
.SYNOPSIS
    Launch SPLAT!'s Leaflet web viewer over a generated PNG + .geo pair.

.DESCRIPTION
    SPLAT! produces a PNG of the coverage map and a Xastir-format .geo
    sidecar with the bounding-box tiepoints; together those are enough
    to overlay the coverage on an OpenStreetMap basemap.  This script
    stages those files alongside viewer/index.html into a temp dir,
    spins up a tiny .NET HttpListener on localhost (no admin needed),
    and opens the browser at it.

.PARAMETER BaseName
    SPLAT! output basename without extension. The script expects
    <BaseName>.png and <BaseName>.geo to exist in -SourceDir.

.PARAMETER SourceDir
    Directory holding the SPLAT! outputs (default: current dir).

.PARAMETER Port
    Localhost port for the static server (default: 8765).

.PARAMETER NoBrowser
    Don't auto-open a browser. Useful when piping or for headless runs.

.EXAMPLE
    splat -t wnju-dt.qth -c 30 -metric -geo -o coverage.png
    ../viewer/launch.ps1 coverage
#>
param(
    [Parameter(Position=0)][string]$BaseName = "coverage",
    [string]$SourceDir = ".",
    [int]$Port = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$srcAbs  = Resolve-Path $SourceDir
$pngPath = Join-Path $srcAbs "$BaseName.png"
$geoPath = Join-Path $srcAbs "$BaseName.geo"

foreach ($p in @($pngPath, $geoPath)) {
    if (-not (Test-Path $p)) {
        Write-Host "FAIL: missing $p" -ForegroundColor Red
        Write-Host "Generate it with:" -ForegroundColor Yellow
        Write-Host "  splat -t ... -c <range> -metric -geo -o $BaseName.png" -ForegroundColor Yellow
        exit 2
    }
}

$serveDir = Join-Path $env:TEMP "splat_viewer_$([guid]::NewGuid().Guid.Substring(0,8))"
New-Item -ItemType Directory -Force -Path $serveDir | Out-Null
Copy-Item $pngPath (Join-Path $serveDir "$BaseName.png") -Force
Copy-Item $geoPath (Join-Path $serveDir "$BaseName.geo") -Force
Copy-Item (Join-Path $PSScriptRoot 'index.html') (Join-Path $serveDir 'index.html') -Force

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.png'  = 'image/png'
    '.geo'  = 'text/plain; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() }
catch {
    Write-Host "FAIL: could not bind http://localhost:$Port/" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Try a different -Port, or run from an elevated shell if needed." -ForegroundColor Yellow
    exit 2
}

$url = "http://localhost:$Port/?name=$BaseName"
Write-Host "" -ForegroundColor Cyan
Write-Host "  SPLAT! viewer up at $url" -ForegroundColor Cyan
Write-Host "  Serving $serveDir" -ForegroundColor DarkGray
Write-Host "  Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $rel = [System.Uri]::UnescapeDataString($req.Url.LocalPath.TrimStart('/'))
        if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }
        # Defensive: refuse path traversal attempts.
        if ($rel.Contains('..')) {
            $res.StatusCode = 403
            $res.Close()
            continue
        }
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
        $res.Close()
    }
} finally {
    $listener.Stop(); $listener.Close()
    Remove-Item -Recurse -Force $serveDir -ErrorAction SilentlyContinue
}
