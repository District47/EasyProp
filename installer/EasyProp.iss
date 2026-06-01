; EasyProp Inno Setup script.
;
; Compiled by scripts\build_installer.ps1 after the release stage dir has been
; populated by scripts\build_release.ps1. The /D defines below are passed in by
; the wrapper so this script stays version-agnostic.
;
;   /DAppVersion="0.4.0"
;   /DStageDir="C:\Users\letsc\AppData\Local\Temp\EasyProp-0.4.0"
;   /DRepoDir="C:\Users\letsc\OneDrive\Documents\splat-main"
;   /DOutputDir="C:\Users\letsc\OneDrive\Documents\splat-main"
;
; Per-user install (no admin / UAC), goes to %LOCALAPPDATA%\Programs\EasyProp.
; Creates a Start Menu shortcut + optional desktop shortcut; uninstaller is
; registered with Windows so EasyProp shows up under Settings -> Apps the same
; as any other installed program.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef StageDir
  #error "StageDir must be defined (path to the populated release-stage dir)"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; AppId pins the upgrade lineage -- changing this would treat upgrades as a
; fresh installation. Keep stable across versions.
AppId={{B7C3F12E-9D44-4F2A-A1C6-3E8D0C7E22B0}
AppName=EasyProp
AppVersion={#AppVersion}
AppVerName=EasyProp {#AppVersion}
AppPublisher=District47
AppPublisherURL=https://district47.us/
AppSupportURL=https://github.com/District47/EasyProp/issues
AppUpdatesURL=https://github.com/District47/EasyProp/releases
DefaultDirName={localappdata}\Programs\EasyProp
DefaultGroupName=EasyProp
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
OutputDir={#OutputDir}
OutputBaseFilename=EasyProp-Setup-{#AppVersion}
SetupIconFile={#SourcePath}\icon.ico
UninstallDisplayIcon={app}\icon.ico
UninstallDisplayName=EasyProp {#AppVersion}
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=District47
VersionInfoDescription=Click-anywhere RF coverage viewer (SPLAT! + ITWOM)
VersionInfoProductName=EasyProp

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; \
    GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; Pull every file from the staged release dir produced by build_release.ps1.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Also drop a copy of the icon next to the launcher so the uninstall-display +
; shortcuts can reference it from {app}\icon.ico after install.
Source: "{#SourcePath}\icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu shortcut -- points at the launcher .bat, but the shortcut's own
; icon (.ico) renders next to the menu entry. Using IconFilename so the .bat's
; default cog icon doesn't show through.
Name: "{autoprograms}\EasyProp"; Filename: "{app}\EasyProp.bat"; \
    IconFilename: "{app}\icon.ico"; WorkingDir: "{app}"; \
    Comment: "RF coverage viewer (SPLAT! + ITWOM)"
Name: "{autodesktop}\EasyProp"; Filename: "{app}\EasyProp.bat"; \
    IconFilename: "{app}\icon.ico"; WorkingDir: "{app}"; \
    Comment: "RF coverage viewer (SPLAT! + ITWOM)"; \
    Tasks: desktopicon

[Run]
Filename: "{app}\EasyProp.bat"; Description: "&Launch EasyProp now"; \
    Flags: nowait postinstall skipifsilent shellexec

[UninstallDelete]
; Leave the user's cache (%LOCALAPPDATA%\EasyProp\) intact on uninstall --
; that's their downloaded SRTM tiles + computed PNGs + saved scenarios +
; custom pins, and they shouldn't lose those just because they uninstalled
; and reinstalled. Reinstall picks up exactly where they left off.
; (No entries here.)
