[Setup]
AppName=StreamPilot
AppVersion={#AppVersion}
AppPublisher=StreamPilot
DefaultDirName={autopf}\StreamPilot
DefaultGroupName=StreamPilot
OutputDir=..\..\installer_output
OutputBaseFilename=streampilot-windows
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
Name: "{group}\StreamPilot"; Filename: "{app}\StreamPilot.exe"
Name: "{group}\{cm:UninstallProgram,StreamPilot}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\StreamPilot"; Filename: "{app}\StreamPilot.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\StreamPilot.exe"; Description: "{cm:LaunchProgram,StreamPilot}"; Flags: nowait postinstall skipifsilent
