; Inno Setup Script for VEO3 Infinity
; This script creates a Windows installer for the Flutter application

#define MyAppName "VEO3 Infinity"
#define MyAppVersion "3.5.0"
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
; Install to user's local app data folder (no admin required, WebView2 can write)
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
; Output settings
OutputDir=installer_output
OutputBaseFilename=VEO3_Infinity_Setup_{#MyAppVersion}
SetupIconFile=assets\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; No admin rights required - installing to user folder
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Architecture
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "quicklaunchicon"; Description: "{cm:CreateQuickLaunchIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked; OnlyBelowVersion: 6.1; Check: not IsAdminInstallMode

[Files]
; Main application files from Flutter build
Source: "build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; FFmpeg - bundled with the application
Source: "ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffprobe.exe"; DestDir: "{app}"; Flags: ignoreversion

; WebView2 Runtime Installer (download from https://go.microsoft.com/fwlink/p/?LinkId=2124703)
; Place MicrosoftEdgeWebview2Setup.exe in your project root
Source: "MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

; Visual C++ Runtime (if needed)
; Uncomment if your app requires VC++ redistributable
; Source: "vcredist_x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Dirs]
; Create default directories in user's local app data (full write permissions)
Name: "{localappdata}\veo3_generator\projects"
Name: "{localappdata}\veo3_generator\videos"
; Profiles directory in app folder
Name: "{app}\profiles"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Install WebView2 Runtime if not already installed
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Flags: waituntilterminated

; Launch the application after installation (optional)
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; Install VC++ Runtime if bundled (uncomment if needed)
; Filename: "{tmp}\vcredist_x64.exe"; Parameters: "/quiet /norestart"; StatusMsg: "Installing Visual C++ Runtime..."; Flags: waituntilterminated

[Code]
// Custom code for installation/uninstallation

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // Create project and export directories if they don't exist
    if not DirExists(ExpandConstant('{localappdata}\veo3_generator\projects')) then
      CreateDir(ExpandConstant('{localappdata}\veo3_generator\projects'));
    if not DirExists(ExpandConstant('{localappdata}\veo3_generator\videos')) then
      CreateDir(ExpandConstant('{localappdata}\veo3_generator\videos'));
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  // Check for Windows 10 or later
  if not IsWin64 then
  begin
    MsgBox('This application requires 64-bit Windows.', mbError, MB_OK);
    Result := False;
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
                         '- All projects in: ' + ExpandConstant('{localappdata}\veo3_generator') + #13#10 +
                         '- All videos in: ' + ExpandConstant('{localappdata}\veo3_generator\videos'),
                         mbConfirmation, MB_YESNO);
    if DeleteData = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}\veo3_generator'), True, True, True);
    end;
  end;
end;
