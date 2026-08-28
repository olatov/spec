unit Joysticks;

{$mode unleashed}

interface

uses
  Classes, SysUtils,
  Raylib;

type
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
    LeftKey, RightKey, UpKey, DownKey, Fire1Key, Fire2Key: TKeyboardKey;
    constructor Create; virtual;
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
    constructor Create; override;
  end;

implementation

function TJoystick.GetDown: Boolean;
begin
  Result := IsKeyDown(DownKey);
end;

function TJoystick.GetFire1: Boolean;
begin
  Result := IsKeyDown(Fire1Key);
end;

function TJoystick.GetFire2: Boolean;
begin
  Result := IsKeyDown(Fire2Key);
end;

function TJoystick.GetKeys: TArray<TKeyboardKey>;
begin
  Result := [LeftKey, RightKey, UpKey, DownKey, Fire1Key, Fire2Key];
end;

function TJoystick.GetLeft: Boolean;
begin
  Result := IsKeyDown(LeftKey);
end;

function TJoystick.GetRight: Boolean;
begin
  Result := IsKeyDown(RightKey);
end;

function TJoystick.GetUp: Boolean;
begin
  Result := IsKeyDown(UpKey);
end;

constructor TJoystick.Create;
begin
  LeftKey := KEY_LEFT;
  RightKey := KEY_RIGHT;
  UpKey := KEY_UP;
  DownKey := KEY_DOWN;
  {$ifdef Darwin}
    Fire1Key := KEY_LEFT_SUPER;
    Fire2Key := KEY_RIGHT_SUPER;
  {$else}
    Fire1Key := KEY_LEFT_ALT;
    Fire2Key := KEY_RIGHT_ALT;
  {$endif}
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

constructor TCursorJoystick.Create;
begin
  inherited Create;
  Fire2Key := KEY_NULL;
end;

end.

