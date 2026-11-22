; Inno Setup Script for VEO3 Infinity
; This script creates a Windows installer for the Flutter application

#define MyAppName "VEO3 Infinity"
#define MyAppVersion "4.3.1"
#define MyAppPublisher "GravityApps"
#define MyAppURL "https://github.com/gravityapps"
#define MyAppExeName "veo3_another.exe"
#define MyAppAssocName MyAppName + " Project"
#define MyAppAssocExt ".veo3proj"
#define MyAppAssocKey StringChange(MyAppAssocName, " ", "") + MyAppAssocExt

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
; Do not use the same AppId value in installers for other applications.
AppId={{B8F3E2A1-5D4C-4B2A-9E8F-1A2B3C4D5E6F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
; Install to LocalAppData â€” user-writable, no admin needed, fixes WebView2 data directory issue
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
; Output settings
OutputDir=installer_output
OutputBaseFilename=VEO3_Infinity_Setup_{#MyAppVersion}
SetupIconFile=assets\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; User-level install â€” no UAC prompt, installs per-user
PrivilegesRequired=lowest
; Architecture
ArchitecturesInstallIn64BitMode=x64 arm64
ArchitecturesAllowed=x64 arm64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main application files from Flutter build
Source: "build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; Node.js runtime for the auto-started extension bridge
Source: "runtime\node.exe"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "runtime\LICENSE"; DestDir: "{app}\runtime"; Flags: ignoreversion

; FFmpeg - bundled with the application
Source: "ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffprobe.exe"; DestDir: "{app}"; Flags: ignoreversion

; WebView2 Runtime Installer (download from https://go.microsoft.com/fwlink/p/?LinkId=2124703)
; Place MicrosoftEdgeWebview2Setup.exe in your project root
Source: "MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

; Playwright Server - Node.js browser automation server (replaces Selenium)
; Build with: cd playwright_server && pkg index.js -t node18-win-x64 -o playwright_server.exe
Source: "playwright_server\playwright_server.exe"; DestDir: "{app}\playwright_server"; Flags: ignoreversion

[Dirs]
; Create default directories in app folder (same location as executable)
Name: "{app}\playwright_server"
Name: "{app}\projects"
Name: "{app}\videos"
Name: "{app}\profiles"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; No longer forcing RunAsAdmin â€” app installs to user-writable LocalAppData
; This fixes WebView2 data directory issues and removes unnecessary UAC prompts

[Run]
; Add Windows Defender exclusions for the app folder (may require elevation for Defender commands)
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -Command ""try {{ Add-MpPreference -ExclusionPath '{app}' -ErrorAction SilentlyContinue }} catch {{}}"""; StatusMsg: "Adding Windows Defender exclusion..."; Flags: runhidden waituntilterminated shellexec
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -Command ""try {{ Add-MpPreference -ExclusionPath '{app}\playwright_server' -ErrorAction SilentlyContinue }} catch {{}}"""; StatusMsg: "Adding Playwright server exclusion..."; Flags: runhidden waituntilterminated shellexec
; User data is now in {app} so no separate exclusion needed

; Install WebView2 Runtime if not already installed
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Flags: waituntilterminated

; Launch the application after installation
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove Windows Defender exclusions on uninstall
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -Command ""Remove-MpPreference -ExclusionPath '{app}' -ErrorAction SilentlyContinue"""; Flags: runhidden
; User data is now in {app} so no separate exclusion needed

[Code]
// Custom code for installation/uninstallation

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    // Create project and export directories if they don't exist
    if not DirExists(ExpandConstant('{app}\projects')) then
      CreateDir(ExpandConstant('{app}\projects'));
    if not DirExists(ExpandConstant('{app}\videos')) then
      CreateDir(ExpandConstant('{app}\videos'));
    if not DirExists(ExpandConstant('{app}\profiles')) then
      CreateDir(ExpandConstant('{app}\profiles'));
  end;
end;

function InitializeSetup(): Boolean;
var
  MFPath: String;
begin
  Result := True;
  // Check for 64-bit Windows
  if not IsWin64 then
  begin
    MsgBox('This application requires 64-bit Windows.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  // Check for Media Foundation (MF.dll) â€” missing on Windows N/KN editions
  MFPath := ExpandConstant('{sys}\MF.dll');
  if not FileExists(MFPath) then
  begin
    if MsgBox('Windows Media Foundation is not installed on this PC.' + #13#10 +
              'VEO3 Infinity requires it for video playback.' + #13#10 + #13#10 +
              'To fix this:' + #13#10 +
              '1. Go to Settings > Apps > Optional Features' + #13#10 +
              '2. Click "Add a feature"' + #13#10 +
              '3. Search for "Media Feature Pack"' + #13#10 +
              '4. Install it and restart your PC' + #13#10 + #13#10 +
              'Or run this command in an admin PowerShell:' + #13#10 +
              'DISM /Online /Add-Capability /CapabilityName:Media.MediaFeaturePack~~~~0.0.1.0' + #13#10 + #13#10 +
              'Do you want to continue the installation anyway?',
              mbError, MB_YESNO) = IDNO then
    begin
      Result := False;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DeleteData: Integer;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Ask user if they want to delete application data
    DeleteData := MsgBox('Do you want to remove all project data and generated videos?' + #13#10 +
                         'This will delete:' + #13#10 +
                         '- All projects in: ' + ExpandConstant('{app}\projects') + #13#10 +
                         '- All videos in: ' + ExpandConstant('{app}\videos') + #13#10 +
                         '- All profiles in: ' + ExpandConstant('{app}\profiles'),
                         mbConfirmation, MB_YESNO);
    if DeleteData = IDYES then
    begin
      DelTree(ExpandConstant('{app}\projects'), True, True, True);
      DelTree(ExpandConstant('{app}\videos'), True, True, True);
      DelTree(ExpandConstant('{app}\profiles'), True, True, True);
    end;
  end;
end;
