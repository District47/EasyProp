<#
.SYNOPSIS
    Build the EasyProp Windows installer (.exe) on top of the release stage.

.DESCRIPTION
    Three-step build:
      1. Run scripts\build_release.ps1 to produce the staged file tree
         (binaries + viewer + utils + EasyProp.bat + README) in
         %TEMP%\EasyProp-<version>\.
      2. (Re)generate installer\icon.ico.
      3. Invoke ISCC (the Inno Setup compiler) on installer\EasyProp.iss
         to produce EasyProp-Setup-<version>.exe at the repo root.

    Output: a single ~2 MB EXE the user double-clicks to install. Per-user
    install (no UAC), Start Menu shortcut, optional desktop shortcut, full
    uninstaller in Settings -> Apps.

.PARAMETER Version
    Version string -- baked into the installer + uninstaller display.

.PARAMETER ISCC
    Path to Inno Setup's ISCC.exe. Auto-detected if omitted.

.EXAMPLE
    .\scripts\build_installer.ps1 -Version 0.4.0
#>
[CmdletBinding()]
param(
    [string]$Version = '0.4.0',
    [string]$ISCC    = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$icon = Join-Path $repo 'installer\icon.ico'
$iss  = Join-Path $repo 'installer\EasyProp.iss'

# 1. Locate ISCC (winget puts it under %LOCALAPPDATA%\Programs\Inno Setup 6;
#    classic installer goes under Program Files (x86)\Inno Setup 6).
if ([string]::IsNullOrEmpty($ISCC)) {
    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )) {
        if (Test-Path $p) { $ISCC = $p; break }
    }
}
if (-not (Test-Path $ISCC)) {
    Write-Error @"
Inno Setup not found. Install it (one-time) then re-run:
    winget install --id JRSoftware.InnoSetup --silent
Or pass -ISCC <full path to ISCC.exe>.
"@
    exit 1
}
Write-Host "ISCC : $ISCC"

# 2. Stage the release files via the existing builder.
Write-Host ""
Write-Host "[1/3] Staging release files via build_release.ps1..." -ForegroundColor Cyan
& (Join-Path $repo 'scripts\build_release.ps1') -Version $Version | Out-Null
$stage = Join-Path $env:TEMP "EasyProp-$Version"
if (-not (Test-Path $stage)) {
    Write-Error "Expected stage dir not found: $stage"; exit 1
}
Write-Host "  Stage dir: $stage"

# 3. Regenerate the icon (also seeds installer\icon.ico if it was deleted).
Write-Host ""
Write-Host "[2/3] Generating app icon..." -ForegroundColor Cyan
& (Join-Path $repo 'installer\build_icon.ps1') -OutFile $icon | Out-Null

# 4. Compile the installer.
Write-Host ""
Write-Host "[3/3] Compiling installer with ISCC..." -ForegroundColor Cyan
$isccArgs = @(
    "/Q",
    "/DAppVersion=$Version",
    "/DStageDir=$stage",
    "/DRepoDir=$repo",
    "/DOutputDir=$repo",
    $iss
)
& $ISCC @isccArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "ISCC failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$out = Join-Path $repo "EasyProp-Setup-$Version.exe"
if (-not (Test-Path $out)) {
    Write-Error "ISCC reported success but installer not found at $out"
    exit 1
}
$sz = (Get-Item $out).Length
Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Green
Write-Host ("  Installer : {0} ({1:N1} MB)" -f $out, ($sz / 1MB))
Write-Host "  Run it to install per-user (no admin needed)."
Write-Host "  Or pass /SILENT for a silent install, /VERYSILENT for fully silent."
