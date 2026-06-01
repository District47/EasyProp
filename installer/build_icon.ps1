<#
.SYNOPSIS
    Generate EasyProp's app icon (icon.ico) procedurally.

.DESCRIPTION
    Draws a 256x256 PNG via System.Drawing -- a teal-to-blue gradient circle
    with a stylized antenna-tower silhouette -- and wraps it in a single-image
    256x256 ICO container. The output is good enough for the Inno Setup
    installer shortcut + Windows shell icon at every standard size that the
    OS will downscale on demand.

    Writing a multi-resolution ICO purely in PowerShell is fiddly (each size
    needs its own ICONDIRENTRY + scaled image), but Windows handles a single
    high-res PNG-encoded ICO entry just fine since Vista. Keeps this script
    short, dependency-free, and reproducible without ImageMagick.

.PARAMETER OutFile
    Where to write the icon.

.EXAMPLE
    .\installer\build_icon.ps1 -OutFile .\installer\icon.ico
#>
param([string]$OutFile = (Join-Path $PSScriptRoot 'icon.ico'))

Add-Type -AssemblyName System.Drawing
$N = 256
$bmp = New-Object System.Drawing.Bitmap $N, $N
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# Background: a circular teal-to-deep-blue gradient (matches the EasyProp
# dark-theme accent colors used in the sidebar).
$bgRect = New-Object System.Drawing.Rectangle 0, 0, $N, $N
$grad   = New-Object System.Drawing.Drawing2D.LinearGradientBrush `
    (New-Object System.Drawing.Point 0, 0), `
    (New-Object System.Drawing.Point $N, $N), `
    ([System.Drawing.Color]::FromArgb(255, 80, 200, 220)), `
    ([System.Drawing.Color]::FromArgb(255, 30, 80, 180))
$g.FillEllipse($grad, $bgRect)

# Thin white rim so the icon reads against any background.
$rim = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(220, 255, 255, 255)), 6
$g.DrawEllipse($rim, 4, 4, $N - 9, $N - 9)

# Antenna tower: a triangular mast with three radio waves arcing out the top.
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$pen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 10
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

# Triangular tower silhouette
$tower = @(
    (New-Object System.Drawing.PointF 128, 80),    # tip
    (New-Object System.Drawing.PointF 95,  205),   # bottom-left
    (New-Object System.Drawing.PointF 161, 205)    # bottom-right
)
$g.FillPolygon($white, $tower)

# Cross-brace bars (give it the lattice-tower look)
$brace = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 30, 80, 180)), 4
$g.DrawLine($brace, 108, 140, 148, 140)
$g.DrawLine($brace, 102, 170, 154, 170)
$g.DrawLine($brace, 113, 110, 143, 110)

# Three concentric radio-wave arcs above the tower's tip
$wavePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 8
$wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$wavePen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
foreach ($r in 20, 38, 56) {
    $rect = New-Object System.Drawing.RectangleF (128 - $r), (80 - $r), (2 * $r), (2 * $r)
    $g.DrawArc($wavePen, $rect, 220, 100)   # arc above tip
}

$g.Dispose()

# Save to in-memory PNG so we can wrap it in an ICO container.
$pngMs = New-Object System.IO.MemoryStream
$bmp.Save($pngMs, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$pngBytes = $pngMs.ToArray()
$pngMs.Dispose()

# ICO file format -- a single 256x256 PNG-encoded entry:
#   ICONDIR     (6 bytes): reserved=0(2), type=1(2), count=1(2)
#   ICONDIRENTRY(16 bytes): w(1)=0 (=256), h(1)=0 (=256), colors(1)=0,
#                           reserved(1)=0, planes(2)=1, bpp(2)=32,
#                           bytesInRes(4)=PNG length, imageOffset(4)=22
#   PNG bytes
$bw = New-Object System.IO.BinaryWriter ([System.IO.File]::Open($OutFile, 'Create'))
$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type = icon
$bw.Write([uint16]1)              # count = 1 entry
$bw.Write([byte]0)                # width  = 256 (0 = 256)
$bw.Write([byte]0)                # height = 256
$bw.Write([byte]0)                # palette colors = 0
$bw.Write([byte]0)                # reserved
$bw.Write([uint16]1)              # color planes
$bw.Write([uint16]32)             # bits per pixel
$bw.Write([uint32]$pngBytes.Length)  # bytes in PNG
$bw.Write([uint32]22)             # offset to PNG data
$bw.Write($pngBytes)
$bw.Close()

$sz = (Get-Item $OutFile).Length
Write-Host ("Wrote $OutFile  ({0:N1} KB)" -f ($sz / 1KB))
