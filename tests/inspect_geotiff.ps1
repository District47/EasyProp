<#
.SYNOPSIS
    Pure-PowerShell GeoTIFF inspector: walks the IFD and dumps the
    width/height + GeoTIFF tags (GeoPixelScale, GeoTiePoints,
    GeoKeyDirectory). Used by the Tier-3 image-geo golden test.
#>
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes($Path)
if ($bytes.Length -lt 8) { throw "Too small to be a TIFF: $($bytes.Length) bytes" }

# --- Header ---
$le = ($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49)   # "II"
$be = ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x4D)   # "MM"
if (-not ($le -or $be)) { throw ("Bad TIFF byte order: " + ('{0:X2} {1:X2}' -f $bytes[0], $bytes[1])) }

function Read-U16([byte[]]$b, [int]$off) {
    if ($script:le) { return [BitConverter]::ToUInt16($b, $off) }
    else { return [uint16](([uint16]$b[$off] -shl 8) -bor $b[$off+1]) }
}
function Read-U32([byte[]]$b, [int]$off) {
    if ($script:le) { return [BitConverter]::ToUInt32($b, $off) }
    else { return [uint32]([uint32]$b[$off]*0x1000000 + [uint32]$b[$off+1]*0x10000 + [uint32]$b[$off+2]*0x100 + [uint32]$b[$off+3]) }
}
function Read-Double([byte[]]$b, [int]$off) {
    if ($script:le) { return [BitConverter]::ToDouble($b, $off) }
    else {
        $r = New-Object byte[] 8; for ($i=0; $i -lt 8; $i++) { $r[$i] = $b[$off+7-$i] }
        return [BitConverter]::ToDouble($r, 0)
    }
}
$script:le = $le

$magic   = Read-U16 $bytes 2
$ifdOff  = Read-U32 $bytes 4
if ($magic -ne 42) { throw ("Bad TIFF magic: $magic (expected 42)") }

# --- IFD ---
$n = Read-U16 $bytes ([int]$ifdOff)
$entryBase = [int]$ifdOff + 2

$tagNames = @{
    256 = 'ImageWidth'; 257 = 'ImageLength'; 258 = 'BitsPerSample'; 259 = 'Compression'
    262 = 'Photometric'; 273 = 'StripOffsets'; 277 = 'SamplesPerPixel'
    278 = 'RowsPerStrip'; 279 = 'StripByteCounts'; 284 = 'PlanarConfig'
    33550 = 'GeoPixelScale'; 33922 = 'GeoTiePoints'; 34735 = 'GeoKeyDirectory'
}

$results = @{}
for ($i = 0; $i -lt $n; $i++) {
    $e = $entryBase + $i * 12
    $tag   = Read-U16 $bytes $e
    $type  = Read-U16 $bytes ($e + 2)
    $count = Read-U32 $bytes ($e + 4)
    $valoff = Read-U32 $bytes ($e + 8)
    $results[[int]$tag] = @{ Type=$type; Count=$count; ValOff=$valoff }
}

# Helpers to fetch tag values out of the IFD entry block.
function Get-IntValue([int]$tag) {
    if (-not $results.ContainsKey($tag)) { return $null }
    $r = $results[$tag]
    # SHORT (type 3) or LONG (type 4); fits in 4 bytes for count==1.
    return [int]$r.ValOff
}
function Get-DoubleArray([int]$tag) {
    if (-not $results.ContainsKey($tag)) { return @() }
    $r = $results[$tag]
    if ($r.Type -ne 12) { throw "Tag $tag is not TIFF_DOUBLE" }
    $arr = New-Object double[] ([int]$r.Count)
    for ($k = 0; $k -lt $r.Count; $k++) {
        $arr[$k] = Read-Double $bytes ([int]$r.ValOff + $k*8)
    }
    return $arr
}
function Get-ShortArray([int]$tag) {
    if (-not $results.ContainsKey($tag)) { return @() }
    $r = $results[$tag]
    if ($r.Type -ne 3) { throw "Tag $tag is not TIFF_SHORT" }
    $arr = New-Object uint16[] ([int]$r.Count)
    for ($k = 0; $k -lt $r.Count; $k++) {
        $arr[$k] = Read-U16 $bytes ([int]$r.ValOff + $k*2)
    }
    return $arr
}

$width  = Get-IntValue 256
$height = Get-IntValue 257
$scale  = Get-DoubleArray 33550
$ties   = Get-DoubleArray 33922
$keys   = Get-ShortArray 34735

[pscustomobject]@{
    File          = $Path
    SizeBytes     = $bytes.Length
    ByteOrder     = if ($le) {'little'} else {'big'}
    Magic         = $magic
    IFDEntries    = $n
    Width         = $width
    Height        = $height
    Compression   = (Get-IntValue 259)
    Photometric   = (Get-IntValue 262)
    SamplesPerPx  = (Get-IntValue 277)
    GeoPixelScale = $scale
    GeoTiePoints  = $ties
    GeoKeyDir     = $keys
}
