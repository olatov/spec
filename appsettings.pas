unit AppSettings;

{$mode unleashed}

interface

uses
  Classes, SysUtils, IniFiles, FGL,
  Raylib;

type
  TDelayDriver = (ddNone = 0, ddDefault, ddRaylib,
    ddSDL3DelayNS, ddSDL3DelayPrecise, ddSleep, ddVSync);

  TAppSettings = class
  private
    FDelayDriverMap: TFPGMap<String, TDelayDriver>;
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
      TVType: Integer;
      Overscan: Integer;
      Curvature: Single;
      Aspect: Boolean;
      ShowFPS: Boolean;
    end;
    Audio: record
      Volume: Single;
      Muted: Boolean;
      Debug: Boolean;
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
      Index: Integer;
      LeftKey, RightKey, UpKey, DownKey, Fire1Key, Fire2Key: TKeyboardKey;
    end;
    Gamepad: record
      Name: String;
    end;
    function ParseDelayDriver(AValue: String): TDelayDriver;
    function DelayDriverToString(AValue: TDelayDriver): String;
    constructor Create(AFilename: String);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
  end;

var
  Settings: TAppSettings;

implementation

function TAppSettings.ParseDelayDriver(AValue: String): TDelayDriver;
begin
  if not FDelayDriverMap.TryGetData(AValue.ToUpper, Result) then
    raise Exception.CreateFmt('Invalid DelayDriver value: "%s"', [AValue]);
end;

function TAppSettings.DelayDriverToString(AValue: TDelayDriver): String;
var
  I: Integer;
begin
  Result := '';

  for I := 0 to FDelayDriverMap.Count - 1 do
  begin
    if FDelayDriverMap.Data[I] = AValue then Result := FDelayDriverMap.Keys[I];
    if not Result.IsEmpty then Exit;
  end;
  Result := '?';
end;

constructor TAppSettings.Create(AFilename: String);
begin
  Filename := AFilename;

  FDelayDriverMap := TFPGMap<String, TDelayDriver>.Create;
  with FDelayDriverMap do
  begin
    Add('', ddDefault);
    Add('NONE', ddNone);
    Add('DEFAULT', ddDefault);
    Add('RAYLIB', ddRaylib);
    Add('SDL3DELAYNS', ddSDL3DelayNS);
    Add('SDL3DELAYPRECISE', ddSDL3DelayPrecise);
    Add('SLEEP', ddSleep);
    Add('VSYNC', ddVSync);
  end;
end;

destructor TAppSettings.Destroy;
begin
  FreeAndNil(FDelayDriverMap);
  inherited Destroy;
end;

procedure TAppSettings.Load;
var
  F: TIniFile;
begin
  F := autofree TIniFile.Create(Filename);

  with System do
  begin
    DelayDriver := ParseDelayDriver(F.ReadString('System', 'DelayDriver', 'default'));
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
    TVType := F.ReadInteger('Display', 'TVType', 0);
    Overscan := F.ReadInteger('Display', 'Overscan', 16);
    Aspect := F.ReadBool('Display', 'Aspect', True);
    Curvature := F.ReadFloat('Display', 'Curvature', 8.0);
    ShowFPS := F.ReadBool('Display', 'ShowFPS', False);
  end;

  with Audio do
  begin
    Muted := F.ReadBool('Audio', 'Muted', False);
    Volume := F.ReadFloat('Audio', 'Volume', 0.25);
    Debug := F.ReadBool('Audio', 'Debug', False);
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

  with Joystick do
  begin
    Index := F.ReadInteger('Joystick', 'Index', 0);
    LeftKey := F.ReadInteger('Joystick', 'LeftKey', KEY_LEFT);
    RightKey := F.ReadInteger('Joystick', 'RightKey', KEY_RIGHT);
    UpKey := F.ReadInteger('Joystick', 'UpKey', KEY_UP);
    DownKey := F.ReadInteger('Joystick', 'DownKey', KEY_DOWN);
    Fire1Key := F.ReadInteger('Joystick', 'Fire1Key',
      {$ifdef darwin} KEY_LEFT_SUPER {$else} KEY_LEFT_ALT {$endif});
    Fire2Key := F.ReadInteger('Joystick', 'Fire2Key',
      {$ifdef darwin} KEY_RIGHT_SUPER {$else} KEY_RIGHT_ALT {$endif});
  end;

  Gamepad.Name := F.ReadString('GamePad', 'Name', '');
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
    F.WriteInteger('Display', 'TVType', TVType);
    F.WriteInteger('Display', 'Overscan', Overscan);
    F.WriteBool('Display', 'Aspect', Aspect);
    F.WriteFloat('Display', 'Curvature', Curvature);
    F.WriteBool('Display', 'ShowFPS', ShowFPS);
  end;

  with Audio do
  begin
    F.WriteBool('Audio', 'Muted', Muted);
    F.WriteFloat('Audio', 'Volume', Volume);
    F.WriteBool('Audio', 'Debug', Debug);
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

  with Joystick do
  begin
    F.WriteInteger('Joystick', 'Index', Index);
    F.WriteInteger('Joystick', 'LeftKey', LeftKey);
    F.WriteInteger('Joystick', 'RightKey', LeftKey);
    F.WriteInteger('Joystick', 'UpKey', UpKey);
    F.WriteInteger('Joystick', 'DownKey', DownKey);
    F.WriteInteger('Joystick', 'Fire1Key', Fire1Key);
    F.WriteInteger('Joystick', 'Fire2Key', Fire2Key);
  end;

  F.WriteString('Gamepad', 'Name', Gamepad.Name);
end;

initialization
  Settings := TAppSettings.Create('spec.conf');
  Settings.Load;

finalization
  Settings.Save;
  FreeAndNil(Settings);

end.

