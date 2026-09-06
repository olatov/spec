unit AppSettings;

{$mode unleashed}

interface

uses
  Classes, SysUtils, IniFiles, System.IOUtils,
  Raylib, Utils, Joysticks;

const
  SettingsFile = 'spec.conf';

type
  TDelayDriver = (
    ddNone = 0,  { No delay between frames, unless forced externally by the OS/platform }
    ddDefault,  { Raylib's WaitTime, no VSync }
    ddVSync, { VSync only; will only produce correct timings if the screen is locked at 50Hz }
    ddSleep  { Sleep }
  );

  TAppSettings = class
  public
    Filename: String;
    System: record
      DelayDriver: TDelayDriver;
      LogLevel: TTraceLogLevel;
    end;
    Window: record
      Width, Height: Integer;
      Fullscreen: Boolean;
      HiDPI: Boolean;
    end;
    Display: record
      TVMode: Integer;
      Overscan: Integer;
      Curvature: Single;
      Aspect: Boolean;
      ShowFPS: Boolean;
    end;
    Audio: record
      Volume: Single;
      Muted: Boolean;
      Stats: Boolean;
    end;
    Keyboard: record
      CapsShiftKey, SymbolShiftKey, BreakSpaceKey: TKeyboardKey;
    end;
    Tape: record
      AutoLoad: Boolean;
      Sound: Boolean;
      Save: Boolean;
    end;
    Files: record
      SavePath: String;
      BrowsePath: String;
    end;
    Joystick: record
      { Which of the machine's joystick interfaces is plugged in. What works
        it is a binding, and those live in TJoystick rather than here - the
        file keeps them in sections of their own. }
      Index: Integer;
    end;
    Gamepad: record
      { The pad to come back to when several are plugged in, remembered by the
        name it reports rather than by the socket it was in. }
      Name: String;
      Deadzone: Single;
    end;
    function ParseDelayDriver(AValue: String): TDelayDriver;
    function DelayDriverToString(AValue: TDelayDriver): String;
    constructor Create(AFilename: String);
    procedure Load;
    procedure Save;
    { Puts the bindings belonging to the pad AName in place of the ones now
      loaded, filing the outgoing pad's away first so nothing taught this
      session is lost when pads are swapped. }
    procedure SwitchGamepadProfile(const AName: String);
  end;

var
  Settings: TAppSettings;

implementation

function TAppSettings.ParseDelayDriver(AValue: String): TDelayDriver;
begin
  case AValue.Trim.ToLower of
    'default', '': Result := ddDefault;
    'none': Result := ddNone;
    'vsync': Result := ddVSync;
    'sleep': Result := ddSleep;
  else
    raise Exception.CreateFmt('Invalid DelayDriver value: "%s"', [AValue]);
  end;
end;

function TAppSettings.DelayDriverToString(AValue: TDelayDriver): String;
begin
  case AValue of
    ddDefault: Result := 'Default';
    ddNone: Result := 'None';
    ddVSync: Result := 'VSync';
    ddSleep: Result := 'Sleep';
  end;
end;

constructor TAppSettings.Create(AFilename: String);
begin
  Filename := AFilename;
end;

procedure TAppSettings.Load;
var
  F: TIniFile;
begin
  F := autofree TIniFile.Create(Filename);

  with System do
  begin
    DelayDriver := ParseDelayDriver(F.ReadString('System', 'DelayDriver',
      {$ifdef PLATFORM_DRM} 'None' {$else} 'Default' {$endif}));
    LogLevel := F.ReadInteger('System', 'LogLevel', LOG_ERROR);
  end;

  with Window do
  begin
    Width := F.ReadInteger('Window', 'Width', 720);
    Height := F.ReadInteger('Window', 'Height', 576);
    Fullscreen := F.ReadBool('Window', 'Fullscreen', True);
    HiDPI := F.ReadBool('Window', 'HiDPI', False);
  end;

  with Display do
  begin
    TVMode := F.ReadInteger('Display', 'TVMode', 0);
    Overscan := F.ReadInteger('Display', 'Overscan', 16);
    Aspect := F.ReadBool('Display', 'Aspect', True);
    Curvature := F.ReadFloat('Display', 'Curvature', 8.0);
    ShowFPS := F.ReadBool('Display', 'ShowFPS', False);
  end;

  with Audio do
  begin
    Muted := F.ReadBool('Audio', 'Muted', False);
    Volume := F.ReadFloat('Audio', 'Volume', 0.35);
    Stats := F.ReadBool('Audio', 'Stats', False);
  end;

  with Keyboard do
  begin
    CapsShiftKey := F.ReadInteger('Keyboard', 'CapsShiftKey', KEY_LEFT_SHIFT);
    SymbolShiftKey := F.ReadInteger('Keyboard', 'SymbolShiftKey',
     {$ifdef darwin} KEY_RIGHT_ALT {$else} KEY_RIGHT_CONTROL {$endif});
    BreakSpaceKey := F.ReadInteger('Keyboard', 'BreakSpaceKey', KEY_SPACE);
  end;

  with Tape do
  begin
    AutoLoad := F.ReadBool('Tape', 'AutoLoad', True);
    Sound := F.ReadBool('Tape', 'Sound', True);
    Save := F.ReadBool('Tape', 'Save', True);
  end;

  with Files do
  begin
    SavePath := F.ReadString('Files', 'SavePath', '');
    BrowsePath := SavePath;
  end;

  Joystick.Index := F.ReadInteger('Joystick', 'Index', 1);

  { The keys only. Which pad is plugged in is not known until raylib is up, so
    its half is loaded later, from SwitchGamepadProfile. }
  TJoystick.LoadBindings(F);

  with Gamepad do
  begin
    Name := F.ReadString('Gamepad', 'Name', '');
    Deadzone := F.ReadFloat('Gamepad', 'Deadzone', 0.5);
  end;
end;

procedure TAppSettings.Save;
var
  F: TIniFile;
begin
  F := autofree TIniFile.Create(Filename);

  with System do
  begin
    F.WriteString('System', 'DelayDriver', DelayDriverToString(DelayDriver));
    F.WriteInteger('System', 'LogLevel', LogLevel);
  end;

  with Window do
  begin
    F.WriteInteger('Window', 'Width', Width);
    F.WriteInteger('Window', 'Height',Height);
    F.WriteBool('Window', 'Fullscreen', Fullscreen);
  end;

  with Display do
  begin
    F.WriteInteger('Display', 'TVMode', TVMode);
    F.WriteInteger('Display', 'Overscan', Overscan);
    F.WriteBool('Display', 'Aspect', Aspect);
    F.WriteFloat('Display', 'Curvature', Curvature);
    F.WriteBool('Display', 'ShowFPS', ShowFPS);
  end;

  with Audio do
  begin
    F.WriteBool('Audio', 'Muted', Muted);
    F.WriteFloat('Audio', 'Volume', Volume);
    F.WriteBool('Audio', 'Debug', Stats);
  end;

  with Keyboard do
  begin
    F.WriteInteger('Keyboard', 'CapsShiftKey', CapsShiftKey);
    F.WriteInteger('Keyboard', 'SymbolShiftKey', SymbolShiftKey);
    F.WriteInteger('Keyboard', 'BreakSpaceKey', BreakSpaceKey);
  end;

  with Tape do
  begin
    F.WriteBool('Tape', 'AutoLoad', AutoLoad);
    F.WriteBool('Tape', 'Sound', Sound);
    F.WriteBool('Tape', 'Save', Save);
  end;

  F.WriteInteger('Joystick', 'Index', Joystick.Index);

  TJoystick.SaveBindings(F);

  with Gamepad do
  begin
    F.WriteString('Gamepad', 'Name', Name);
    F.WriteFloat('Gamepad', 'Deadzone', Deadzone);
  end;
end;

procedure TAppSettings.SwitchGamepadProfile(const AName: String);
var
  F: TIniFile;
begin
  F := autofree TIniFile.Create(Filename);

  { Whatever the player taught the outgoing pad is filed under its name before
    the incoming pad's bindings take its place in memory. }
  TJoystick.SaveGamepadBindings(F);

  { A pad going away leaves the bindings where they are: there is nothing to
    put in their place, and it is most likely the same pad coming back. }
  if not AName.IsEmpty then TJoystick.LoadGamepadBindings(F, AName);
end;

initialization
  Settings := TAppSettings.Create(TPath.Combine(UserDataDir, SettingsFile));
  Settings.Load;

finalization
  Settings.Save;
  FreeAndNil(Settings);

end.

