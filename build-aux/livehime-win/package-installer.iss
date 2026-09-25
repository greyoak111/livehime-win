; Inno Setup script for LiveHime for Windows.
;
; Bilibili's own Windows client is an Inno Setup package (see
; docs/WINDOWS_PORT.md), so this is the same installer technology the product
; it reimplements uses.
;
; Build:
;   ISCC.exe /DAppVersion=0.2.10 /DSourceDir=C:\build\obs-livehime\build_x64\rundir\RelWithDebInfo \
;            /DOutputDir=C:\build build-aux\livehime-win\package-installer.iss
;
; The result is a per-user install, which is deliberate: an update replaces the
; whole install tree, and %LOCALAPPDATA%\Programs is writable without
; elevation. Installing under Program Files would make every update need an
; administrator, and the macOS build has no such requirement.

#ifndef AppVersion
  #define AppVersion "0.2.10"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build_x64\rundir\RelWithDebInfo"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build_x64"
#endif
#ifndef AppArch
  #define AppArch "x64"
#endif

[Setup]
AppId={{8E1F2C74-6B3A-4A9D-9C1E-7F4B2A5D3C10}
AppName=LiveHime
AppVersion={#AppVersion}
AppVerName=LiveHime {#AppVersion}
AppPublisher=LiveHime
VersionInfoProductName=LiveHime
VersionInfoProductVersion={#AppVersion}
; Same shape as the exe's version resource: the product version is LiveHime's,
; the file version stays the OBS release this is built on.
VersionInfoVersion={#AppVersion}

DefaultDirName={autopf}\LiveHime
DefaultGroupName=LiveHime
DisableProgramGroupPage=yes
AllowNoIcons=yes

; Per-user: see the header. {autopf} resolves to %LOCALAPPDATA%\Programs here
; because PrivilegesRequired=lowest.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

OutputDir={#OutputDir}
OutputBaseFilename=LiveHime-Setup-v{#AppVersion}-{#AppArch}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayName=LiveHime {#AppVersion}
UninstallDisplayIcon={app}\bin\64bit\obs64.exe

[Languages]
Name: "chinese"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole run tree. `recursesubdirs createallsubdirs` walks bin, obs-plugins
; and data; the debug symbols were stripped before packaging, so what is here
; is what the app runs.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LiveHime"; Filename: "{app}\bin\64bit\obs64.exe"; WorkingDir: "{app}\bin\64bit"
Name: "{group}\{cm:UninstallProgram,LiveHime}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\LiveHime"; Filename: "{app}\bin\64bit\obs64.exe"; WorkingDir: "{app}\bin\64bit"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\64bit\obs64.exe"; Description: "{cm:LaunchProgram,LiveHime}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The updater keeps the replaced tree beside the install tree; an uninstall
; should not leave that behind.
Type: filesandordirs; Name: "{app}\..\{#AppName}.livehime-previous"
Type: filesandordirs; Name: "{app}\..\{#AppName}.livehime-staged-*"
