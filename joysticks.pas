unit Joysticks;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Nullable,
  Raylib;

type
  { The six things a joystick can report. }
  TJoystickControl = (jcLeft, jcRight, jcUp, jcDown, jcFire1, jcFire2);
  TJoystickBindings = array[TJoystickControl] of TKeyboardKey;

  { The interface a game reads its stick through. Which host keys stand for the
    stick is not part of that - the player has one set of movement keys, and
    switching between a Kempston and a Cursor interface must not change them -
    so the bindings are shared by every joystick rather than owned by one. }
  TJoystick = class abstract
  private
    function GetDown: Boolean;
    function GetFire1: Boolean;
    function GetFire2: Boolean;
    function GetKeys: TArray<TKeyboardKey>;
    function GetLeft: Boolean;
    function GetRight: Boolean;
    function GetUp: Boolean;
  public
    class var Bindings: TJoystickBindings;
    class var GamepadIndex: TNullable<Integer>;
    { The built-in bindings, also what an absent config setting falls back to. }
    class procedure ResetBindings; static;
    { True while the key bound to AControl is held. An unbound control (its
      binding cleared to KEY_NULL) is never down. }
    class function IsDown(AControl: TJoystickControl): Boolean; static;
    { Clears every other control bound to AKey, so one keystroke can never
      mean two directions at once. }
    class procedure Bind(AControl: TJoystickControl; AKey: TKeyboardKey); static;
    function Poll(APort: Word): Byte; virtual; abstract;
    property Left: Boolean read GetLeft;
    property Right: Boolean read GetRight;
    property Up: Boolean read GetUp;
    property Down: Boolean read GetDown;
    property Fire1: Boolean read GetFire1;
    property Fire2: Boolean read GetFire2;
    property Keys: TArray<TKeyboardKey> read GetKeys;
  end;

  TKempstonJoystick = class(TJoystick)
    function Poll(APort: Word): Byte; override;
  end;

  TCursorJoystick = class(TJoystick)
    function Poll(APort: Word): Byte; override;
  end;

const
  { Both the label a binding is shown under and the config key it is written
    as - a name here is part of the config format. }
  JoystickControlNames: array[TJoystickControl] of String =
    ('Left', 'Right', 'Up', 'Down', 'Fire1', 'Fire2');

implementation

class procedure TJoystick.ResetBindings; static;
begin
  Bindings[jcLeft] := KEY_LEFT;
  Bindings[jcRight] := KEY_RIGHT;
  Bindings[jcUp] := KEY_UP;
  Bindings[jcDown] := KEY_DOWN;
  {$ifdef Darwin}
    Bindings[jcFire1] := KEY_LEFT_SUPER;
    Bindings[jcFire2] := KEY_RIGHT_SUPER;
  {$else}
    Bindings[jcFire1] := KEY_LEFT_ALT;
    Bindings[jcFire2] := KEY_RIGHT_ALT;
  {$endif}
end;

class function TJoystick.IsDown(AControl: TJoystickControl): Boolean; static;
begin
  Result := (Bindings[AControl] <> KEY_NULL) and IsKeyDown(Bindings[AControl]);
end;

class procedure TJoystick.Bind(AControl: TJoystickControl; AKey: TKeyboardKey); static;
var
  Control: TJoystickControl;
begin
  if AKey <> KEY_NULL then
    for Control := Low(TJoystickControl) to High(TJoystickControl) do
      if (Control <> AControl) and (Bindings[Control] = AKey) then
        Bindings[Control] := KEY_NULL;

  Bindings[AControl] := AKey;
end;

function TJoystick.GetKeys: TArray<TKeyboardKey>;
begin
  Result := [Bindings[jcLeft], Bindings[jcRight], Bindings[jcUp],
    Bindings[jcDown], Bindings[jcFire1], Bindings[jcFire2]];
end;

function TJoystick.GetDown: Boolean;
begin
  Result := IsDown(jcDown);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex.Value, GAMEPAD_BUTTON_LEFT_FACE_DOWN));
end;

function TJoystick.GetFire1: Boolean;
begin
  Result := IsDown(jcFire1);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex, GAMEPAD_BUTTON_RIGHT_FACE_DOWN));
end;

function TJoystick.GetFire2: Boolean;
begin
  Result := IsDown(jcFire2);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex, GAMEPAD_BUTTON_RIGHT_FACE_LEFT));
end;

function TJoystick.GetLeft: Boolean;
begin
  Result := IsDown(jcLeft);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex, GAMEPAD_BUTTON_LEFT_FACE_LEFT));
end;

function TJoystick.GetRight: Boolean;
begin
  Result := IsDown(jcRight);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex, GAMEPAD_BUTTON_LEFT_FACE_RIGHT));
end;

function TJoystick.GetUp: Boolean;
begin
  Result := IsDown(jcUp);
  Result := Result or (GamePadIndex.HasValue and IsGamepadButtonDown(GamepadIndex, GAMEPAD_BUTTON_LEFT_FACE_UP));
end;

function TKempstonJoystick.Poll(APort: Word): Byte;
begin
  Result := 0;
  Result.Bits[0] := Right;
  Result.Bits[1] := Left;
  Result.Bits[2] := Down;
  Result.Bits[3] := Up;
  Result.Bits[4] := Fire1;
  Result.Bits[5] := Fire2;
end;

function TCursorJoystick.Poll(APort: Word): Byte;
begin
  Result := 0;

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

initialization
  TJoystick.ResetBindings;

end.
