#define MyAppName "SysInput"
#define MyAppVersion "0.2.0-rc2"
#define MyAppPublisher "SysInput"
#define MyAppExeName "SysInput.exe"
#define ProjectRoot SourcePath + "\.."

[Setup]
AppId={{E1559668-7C29-4BE8-9F00-195A8CF865B4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#ProjectRoot}\dist
OutputBaseFilename=SysInput-Setup-{#MyAppVersion}
SetupIconFile={#ProjectRoot}\resources\sysinput.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile={#ProjectRoot}\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
UsePreviousTasks=yes
VersionInfoVersion=0.2.0.0
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion=0.2.0.0
VersionInfoDescription=SysInput installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startup"; Description: "Start SysInput with Windows"; GroupDescription: "Startup:";
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#ProjectRoot}\zig-out\bin\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion restartreplace
Source: "{#ProjectRoot}\resources\dictionary.txt"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#ProjectRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\SysInput"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--background"; WorkingDir: "{app}"
Name: "{group}\Uninstall SysInput"; Filename: "{uninstallexe}"
Name: "{autodesktop}\SysInput"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--background"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "SysInput"; ValueData: """{app}\{#MyAppExeName}"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--background"; Description: "Launch SysInput"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--shutdown"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "ShutdownSysInput"

[Code]
const
  WM_CLOSE = $0010;

var
  DeleteUserData: Boolean;
  DeleteChoiceMade: Boolean;

function FindWindow(lpClassName, lpWindowName: string): HWND;
  external 'FindWindowW@user32.dll stdcall';
function PostMessage(hWnd: HWND; Msg: LongWord; wParam, lParam: LongInt): Boolean;
  external 'PostMessageW@user32.dll stdcall';

function StopRunningSysInput(): Boolean;
var
  WindowHandle: HWND;
  Attempt: Integer;
begin
  Result := True;
  WindowHandle := FindWindow('SysInputLifecycleWindow', 'SysInput');
  if WindowHandle = 0 then
    exit;

  if not PostMessage(WindowHandle, WM_CLOSE, 0, 0) then
  begin
    Result := False;
    exit;
  end;

  for Attempt := 1 to 50 do
  begin
    Sleep(100);
    if FindWindow('SysInputLifecycleWindow', 'SysInput') = 0 then
      exit;
  end;
  Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopRunningSysInput() then
    Result := 'SysInput is still running. Exit it from the tray and retry the installation.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (not WizardIsTaskSelected('startup')) then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'SysInput');
end;

function InitializeUninstall(): Boolean;
begin
  DeleteUserData := False;
  DeleteChoiceMade := False;
  Result := True;
end;

function ShouldDeleteUserData(): Boolean;
begin
  if Pos('/DELETEUSERDATA', Uppercase(GetCmdTail)) > 0 then
  begin
    Result := True;
    exit;
  end;

  if UninstallSilent then
  begin
    Result := False;
    exit;
  end;

  if not DeleteChoiceMade then
  begin
    DeleteUserData :=
      MsgBox(
        'Also delete SysInput settings, imported corpus indexes, abbreviations, and learned data?' + #13#10 + #13#10 +
        'Choose No to preserve them for a future installation. Original corpus source files are never deleted.',
        mbConfirmation, MB_YESNO) = IDYES;
    DeleteChoiceMade := True;
  end;
  Result := DeleteUserData;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and ShouldDeleteUserData() then
    DelTree(ExpandConstant('{localappdata}\SysInput'), True, True, True);
end;
