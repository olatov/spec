unit Joysticks;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Nullable,
  Raylib;

type
  { The six things a joystick can report. }
  TJoystickControl = (jcLeft, jcRight, jcUp, jcDown, jcFire1, jcFire2);
  TJoystickKeyBindings = array[TJoystickControl] of TKeyboardKey;
  TJoystickGamepadBindings = array[TJoystickControl] of TGamepadButton;

  { The interface a game reads its stick through. Which host keys stand for the
    stick is not part of that - the player has one set of movement keys, and
    switching between a Kempston and a Cursor interface must not change them -
    so the bindings are shared by every joystick rather than owned by one. }
  TJoystick = class abstract
  private
    class var FIsGamepadAvailable: Boolean;
    function GetDown: Boolean;
    function GetFire1: Boolean;
    function GetFire2: Boolean;
    function GetKeys: TArray<TKeyboardKey>;
    function GetLeft: Boolean;
    function GetName: String; virtual;
    function GetRight: Boolean;
    function GetUp: Boolean;
  public
    property Name: String read GetName;
    class var KeyBindings: TJoystickKeyBindings;
    class var GamepadBindings: TJoystickGamepadBindings;
    class var GamepadIndex: TNullable<Integer>;
    { The built-in KeyBindings, also what an absent config setting falls back to. }
    class procedure ResetBindings; static;
    { True while the key bound to AControl is held. An unbound control (its
      binding cleared to KEY_NULL) is never down. }
    class function IsDown(AControl: TJoystickControl): Boolean; static;
    { Clears every other control bound to AKey, so one keystroke can never
      mean two directions at once. }
    class procedure Bind(AControl: TJoystickControl; AKey: TKeyboardKey); static;
    function Poll(APort: Word): Byte; virtual;
    property Left: Boolean read GetLeft;
    property Right: Boolean read GetRight;
    property Up: Boolean read GetUp;
    property Down: Boolean read GetDown;
    property Fire1: Boolean read GetFire1;
    property Fire2: Boolean read GetFire2;
    property Keys: TArray<TKeyboardKey> read GetKeys;
  end;

  TKeySimulatorJoystick = class(TJoystick);

  TKempstonJoystick = class(TJoystick)
    function GetName: String; override;
    function Poll(APort: Word): Byte; override;
  end;

  TCursorJoystick = class(TKeySimulatorJoystick)
    function GetName: String; override;
    function Poll(APort: Word): Byte; override;
  end;

  TSpanishJoystick = class(TKeySimulatorJoystick)
    { OPQAM }
    function GetName: String; override;
    function Poll(APort: Word): Byte; override;
  end;

  TSinclairJoystick = class(TKeySimulatorJoystick)
  { 12345 / 67890 }
  public
    type
      TSinclairJoystickIndex = 1..2;
  private
    FIndex: TSinclairJoystickIndex;
  public
    property Index: TSinclairJoystickIndex read FIndex;
    constructor Create(AIndex: TSinclairJoystickIndex); reintroduce;
    function GetName: String; override;
    function Poll(APort: Word): Byte; override;
  end;

const
  { Both the label a binding is shown under and the config key it is written
    as - a name here is part of the config format. }
  JoystickControlNames: array[TJoystickControl] of String =
    ('Left', 'Right', 'Up', 'Down', 'Fire 1', 'Fire 2');

implementation

class procedure TJoystick.ResetBindings; static;
begin
  KeyBindings[jcLeft] := KEY_LEFT;
  KeyBindings[jcRight] := KEY_RIGHT;
  KeyBindings[jcUp] := KEY_UP;
  KeyBindings[jcDown] := KEY_DOWN;
  {$ifdef Darwin}
    KeyBindings[jcFire1] := KEY_LEFT_SUPER;
    KeyBindings[jcFire2] := KEY_RIGHT_SUPER;
  {$else}
    KeyBindings[jcFire1] := KEY_LEFT_ALT;
    KeyBindings[jcFire2] := KEY_RIGHT_ALT;
  {$endif}

  GamepadBindings[jcLeft] := GAMEPAD_BUTTON_LEFT_FACE_LEFT;
  GamepadBindings[jcRight] := GAMEPAD_BUTTON_LEFT_FACE_RIGHT;
  GamepadBindings[jcUp] := GAMEPAD_BUTTON_LEFT_FACE_UP;
  GamepadBindings[jcDown] := GAMEPAD_BUTTON_LEFT_FACE_DOWN;
  GamepadBindings[jcFire1] := GAMEPAD_BUTTON_RIGHT_FACE_DOWN;
  GamepadBindings[jcFire2] := GAMEPAD_BUTTON_RIGHT_FACE_LEFT;
end;

class function TJoystick.IsDown(AControl: TJoystickControl): Boolean; static;
begin
  Result := (KeyBindings[AControl] <> KEY_NULL) and IsKeyDown(KeyBindings[AControl]);
  if FIsGamepadAvailable then
    Result := Result or IsGamepadButtonDown(GamepadIndex.Value, GamepadBindings[AControl]);
end;

class procedure TJoystick.Bind(AControl: TJoystickControl; AKey: TKeyboardKey); static;
var
  Control: TJoystickControl;
begin
  if AKey <> KEY_NULL then
    for Control := Low(TJoystickControl) to High(TJoystickControl) do
      if (Control <> AControl) and (KeyBindings[Control] = AKey) then
        KeyBindings[Control] := KEY_NULL;

  KeyBindings[AControl] := AKey;
end;

function TJoystick.Poll(APort: Word): Byte;
begin
  Result := 0;
  FIsGamepadAvailable := GamepadIndex.HasValue
    and Raylib.IsGamepadAvailable(GamepadIndex.Value);
end;

function TJoystick.GetKeys: TArray<TKeyboardKey>;
begin
  Result := [KeyBindings[jcLeft], KeyBindings[jcRight], KeyBindings[jcUp],
    KeyBindings[jcDown], KeyBindings[jcFire1], KeyBindings[jcFire2]];
end;

function TJoystick.GetDown: Boolean;
begin
  Result := IsDown(jcDown);
end;

function TJoystick.GetFire1: Boolean;
begin
  Result := IsDown(jcFire1);
end;

function TJoystick.GetFire2: Boolean;
begin
  Result := IsDown(jcFire2);
end;

function TJoystick.GetLeft: Boolean;
begin
  Result := IsDown(jcLeft);
end;

function TJoystick.GetName: String;
begin

end;

function TJoystick.GetRight: Boolean;
begin
  Result := IsDown(jcRight);
end;

function TJoystick.GetUp: Boolean;
begin
  Result := IsDown(jcUp);
end;

function TKempstonJoystick.GetName: String;
begin
  Result := 'Kempston';
end;

function TKempstonJoystick.Poll(APort: Word): Byte;
begin
  Result := inherited Poll(APort);

  Result.Bits[0] := Right;
  Result.Bits[1] := Left;
  Result.Bits[2] := Down;
  Result.Bits[3] := Up;
  Result.Bits[4] := Fire1;
  Result.Bits[5] := Fire2;
end;

function TCursorJoystick.GetName: String;
begin
  Result := 'Cursor / Protek';
end;

function TCursorJoystick.Poll(APort: Word): Byte;
begin
  Result := inherited Poll(APort);

  if not APort.Bits[12] then
  begin
    { $EFFE }
    Result.Bits[0] := Result.Bits[0] or Fire1;
    Result.Bits[2] := Result.Bits[2] or Right;
    Result.Bits[3] := Result.Bits[3] or Up;
    Result.Bits[4] := Result.Bits[4] or Down;
  end;

  if not APort.Bits[11] then
    { $F7FE }
    Result.Bits[4] := Result.Bits[4] or Left;

  Result := not Result;
end;

function TSpanishJoystick.GetName: String;
begin
  Result := 'Spanish / QAOPM';
end;

function TSpanishJoystick.Poll(APort: Word): Byte;
begin
  Result := inherited Poll(APort);

  { $FDFE }
  if not APort.Bits[9] then
    Result.Bits[0] := Result.Bits[0] or Down; { A }

  { $FBFE }
  if not APort.Bits[10] then
    Result.Bits[0] := Result.Bits[0] or Up; { Q }

  { $DFFE }
  if not APort.Bits[13] then
  begin
    Result.Bits[0] := Result.Bits[0] or Right; { P }
    Result.Bits[1] := Result.Bits[1] or Left;  { O }
  end;

  { $7FFE }
  if not APort.Bits[15] then
  begin
    Result.Bits[0] := Result.Bits[0] or Fire2; { Space }
    Result.Bits[2] := Result.Bits[2] or Fire1; { M }
  end;

  Result := not Result;
end;

constructor TSinclairJoystick.Create(AIndex: TSinclairJoystickIndex);
begin
  FIndex := AIndex;
end;

function TSinclairJoystick.GetName: String;
var
  Info: array[1..2] of String = ('12345', '67890');
begin
  Result := $'Sinclair / {Info[Index]}';
end;

function TSinclairJoystick.Poll(APort: Word): Byte;
begin
  Result := inherited Poll(APort);

  case Index of
    1:
      { $F7FE }
      if not APort.Bits[11] then
      begin
        Result.Bits[0] := Result.Bits[0] or Left;
        Result.Bits[1] := Result.Bits[1] or Right;
        Result.Bits[2] := Result.Bits[2] or Down;
        Result.Bits[3] := Result.Bits[3] or Up;
        Result.Bits[4] := Result.Bits[4] or Fire1;
      end;

    2:
      { $EFFE }
      if not APort.Bits[12] then
      begin
        Result.Bits[0] := Fire1;
        Result.Bits[1] := Up;
        Result.Bits[2] := Down;
        Result.Bits[3] := Right;
        Result.Bits[4] := Left;
      end;
  end;

  Result := not Result;
end;

initialization
  TJoystick.ResetBindings;

end.
