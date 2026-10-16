; RaptorMod.iss -- the player's setup wizard (Inno Setup 6). Built by tools\Build-Release.ps1, which passes:
;   /DAppVer=<version>  /DStage=<staged package>  /DTextures=<textures\hires>  /DOutDir=<output folder>
; The wizard copies the mod into one folder, then runs app\tools\Install-Game.ps1, which builds the game from the
; player's own Steam copy (nothing of the publisher's is in this package). Steam's folder is never written.

#ifndef AppVer
  #define AppVer "0.0.0"
#endif

[Setup]
AppId={{6B2F1D3A-7C41-4E5B-9A8D-52C0F1E7A3B9}
AppName=RaptorMod
AppVersion={#AppVer}
AppVerName=RaptorMod {#AppVer}
AppPublisher=RaptorMod
AppComments=A remaster patch for Azrael's Tear (requires the Steam version)
DefaultDirName=C:\Games\RaptorMod
DefaultGroupName=RaptorMod
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
DirExistsWarning=no
PrivilegesRequired=lowest
WizardStyle=modern
LicenseFile={#Stage}\root\THIRD-PARTY-NOTICES.txt
InfoBeforeFile={#Stage}\root\README.txt
OutputDir={#OutDir}
OutputBaseFilename=RaptorMod-{#AppVer}-Setup
; PNG and movie data are compressed already: fast LZMA, not solid, keeps building and installing quick
Compression=lzma2/fast
SolidCompression=no
; slices under 2 GB: fits ModDB, a NAS folder or any web host
DiskSpanning=yes
DiskSliceSize=1900000000
SlicesPerDisk=1
UninstallDisplayName=RaptorMod {#AppVer}
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#Stage}\app\*";     DestDir: "{app}\app";            Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\payload\*"; DestDir: "{app}\payload";        Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\root\*";    DestDir: "{app}";                Flags: ignoreversion
Source: "{#Textures}\*";      DestDir: "{app}\textures\hires"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Play RaptorMod";                   Filename: "{app}\Play RaptorMod.cmd";                   WorkingDir: "{app}"
Name: "{group}\Play RaptorMod (Classic 8-bit)";   Filename: "{app}\Play RaptorMod (Classic 8-bit).cmd";   WorkingDir: "{app}"
Name: "{group}\Collect Logs";                     Filename: "{app}\Collect Logs.cmd";                     WorkingDir: "{app}"
Name: "{group}\Repair RaptorMod";                 Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\app\tools\Install-Game.ps1"""; WorkingDir: "{app}"
Name: "{group}\Read Me";                          Filename: "{app}\README.txt"
Name: "{group}\Uninstall RaptorMod";              Filename: "{uninstallexe}"
Name: "{autodesktop}\RaptorMod";                  Filename: "{app}\Play RaptorMod.cmd";                   WorkingDir: "{app}"; Tasks: desktopicon

[UninstallDelete]
; everything the builder made from the player's copy, plus the caches (the saves are inside game\)
Type: filesandordirs; Name: "{app}\cache"
Type: filesandordirs; Name: "{app}\game"
Type: filesandordirs; Name: "{app}\payload"
Type: filesandordirs; Name: "{app}\textures"
Type: filesandordirs; Name: "{app}\app"
Type: files;          Name: "{app}\raptormod-root.txt"
Type: dirifempty;     Name: "{app}"

[Code]
var
  SteamPage: TInputDirWizardPage;
  BuildFailed: Boolean;

function IsSteamGame(const Dir: String): Boolean;
begin
  Result := (Dir <> '') and FileExists(AddBackslash(Dir) + 'GAME\AZRAEL\R.EXE') and FileExists(AddBackslash(Dir) + 'AZT.BIN');
end;

{ Steam's own library first; the builder searches every library listed in libraryfolders.vdf when this is left empty }
function DetectSteamGame(): String;
var
  SteamPath, Cand: String;
begin
  Result := '';
  if RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamPath) then
  begin
    StringChangeEx(SteamPath, '/', '\', True);
    Cand := AddBackslash(SteamPath) + 'steamapps\common\Azrael''s Tear';
    if IsSteamGame(Cand) then Result := Cand;
  end;
end;

procedure InitializeWizard();
begin
  SteamPage := CreateInputDirPage(wpSelectDir, 'Azrael''s Tear (Steam)',
    'Where is Azrael''s Tear installed?',
    'RaptorMod copies the game from your Steam installation and patches the copy; your Steam folder is not changed.' + #13#10 +
    'Leave this empty to search all of your Steam libraries.', False, '');
  SteamPage.Add('');
  SteamPage.Values[0] := DetectSteamGame();
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  D: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    D := WizardDirValue();
    if Pos(LowerCase(ExpandConstant('{pf}')), LowerCase(D)) = 1 then
    begin
      SuppressibleMsgBox('Please choose a folder outside Program Files (for example C:\Games\RaptorMod): RaptorMod writes its saves, settings and caches inside its own folder.', mbError, MB_OK, IDOK);
      Result := False;
    end
    else if DirExists(AddBackslash(D) + 'game') and not FileExists(AddBackslash(D) + 'raptormod-root.txt') then
    begin
      SuppressibleMsgBox('This folder already holds a RaptorMod setup that this installer did not make (a developer install). Please choose a different folder.', mbError, MB_OK, IDOK);
      Result := False;
    end;
  end
  else if CurPageID = SteamPage.ID then
  begin
    D := Trim(SteamPage.Values[0]);
    if (D <> '') and not IsSteamGame(D) then
    begin
      SuppressibleMsgBox('That folder does not contain Azrael''s Tear (GAME\AZRAEL\R.EXE and AZT.BIN). Choose the game''s folder in your Steam library, or leave the box empty to search.', mbError, MB_OK, IDOK);
      Result := False;
    end;
  end;
end;

{ after the files are in: build the game from the player's own copy (a visible window shows the progress) }
procedure CurStepChanged(CurStep: TSetupStep);
var
  Params, D: String;
  RC: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Building the game from your Steam copy (a few minutes; see the progress window)...';
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\app\tools\Install-Game.ps1" -NoPause';
    D := Trim(SteamPage.Values[0]);
    if D <> '' then Params := Params + ' -SteamDir "' + D + '"';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, ExpandConstant('{app}'), SW_SHOWNORMAL, ewWaitUntilTerminated, RC) or (RC <> 0) then
    begin
      BuildFailed := True;
      SuppressibleMsgBox('RaptorMod''s files are installed, but building the game from your Steam copy did not finish.' + #13#10#13#10 +
             'The reason is at the end of:' + #13#10 + ExpandConstant('{app}') + '\cache\install.log' + #13#10#13#10 +
             'Fix it (for example: verify the game''s files in Steam), then run "Repair RaptorMod" from the Start menu.', mbError, MB_OK, IDOK);
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: String;
begin
  S := Trim(SteamPage.Values[0]);
  if S = '' then S := '(found automatically in your Steam libraries)';
  Result := MemoDirInfo + NewLine + NewLine + 'Azrael''s Tear (Steam):' + NewLine + Space + S + NewLine + NewLine + MemoTasksInfo;
end;
