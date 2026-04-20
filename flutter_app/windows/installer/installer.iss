[Setup]
AppName=IPTV Player
AppVersion={#AppVersion}
AppPublisher=IPTV Player
DefaultDirName={autopf}\IPTV Player
DefaultGroupName=IPTV Player
OutputDir=..\..\installer_output
OutputBaseFilename=iptv-player-windows
Compression=lzma2
SolidCompression=yes
SetupIconFile=
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\IPTV Player"; Filename: "{app}\flutter_app.exe"
Name: "{group}\{cm:UninstallProgram,IPTV Player}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\IPTV Player"; Filename: "{app}\flutter_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\flutter_app.exe"; Description: "{cm:LaunchProgram,IPTV Player}"; Flags: nowait postinstall skipifsilent
