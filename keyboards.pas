unit Keyboards;

{$mode unleashed}

interface

uses
  Classes, SysUtils,
  Raylib;

type
  TKeyArray = array of TKeyboardKey;

  TKeyboard = class
  private
    class function GetKeyName(AKey: TKeyboardKey): String; static;
  public
    SymbolShiftKeys: TKeyArray;
    CapsShiftKeys: TKeyArray;
    BreakSpaceKeys: TKeyArray;
    class property KeyName[AKey: TKeyboardKey]: String read GetKeyName;
    class function GetKeyNames(AKeys: TKeyArray): TStringArray;
    constructor Create;
    function Poll(APort: Word): Byte;
  end;

implementation

class function TKeyboard.GetKeyName(AKey: TKeyboardKey): String; static;
begin
  case AKey of
    KEY_ESCAPE: Result := 'Esc';
    KEY_ENTER: Result := 'Enter';
    KEY_SPACE: Result := 'Space';
    KEY_BACKSPACE: Result := 'Backspace';
    KEY_LEFT: Result := 'Left';
    KEY_RIGHT: Result := 'Right';
    KEY_UP: Result := 'Up';
    KEY_DOWN: Result := 'Down';
    KEY_LEFT_SHIFT: Result := 'Left SHIFT';
    KEY_RIGHT_SHIFT: Result := 'Right SHIFT';
    KEY_LEFT_CONTROL: Result := 'Left CTRL';
    KEY_RIGHT_CONTROL: Result := 'Right CTRL';
    KEY_LEFT_ALT: Result := 'Left ALT';
    KEY_RIGHT_ALT: Result := 'Right ALTL';
  else
    Result := Raylib.GetKeyName(AKey);
  end;

  Result := Result.ToUpper;
end;

class function TKeyboard.GetKeyNames(AKeys: TKeyArray): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(AKeys));
  for I := 0 to High(AKeys) do
    Result[I] := KeyName[AKeys[I]];
end;

constructor TKeyboard.Create;
begin
  CapsShiftKeys := [KEY_LEFT_SHIFT, KEY_RIGHT_SHIFT];
  SymbolShiftKeys := [KEY_RIGHT_CONTROL, KEY_LEFT_CONTROL];
  BreakSpaceKeys := [KEY_SPACE];
end;

function TKeyboard.Poll(APort: Word): Byte;
var
  Data: Integer;
  Key: TKeyboardKey;
begin
  if APort.Bits[0] then Exit($FF);

  Result := 0;
  Data := 0;

  if not APort.Bits[8] then
  begin
    { $FEFE }
    for Key in CapsShiftKeys do
      Data.Bits[0] := Data.Bits[0] or IsKeyDown(Key);

    Data.Bits[0] := Data.Bits[0] or IsKeyDown(KEY_BACKSPACE);
    Data.Bits[1] := IsKeyDown(KEY_Z);
    Data.Bits[2] := IsKeyDown(KEY_X);
    Data.Bits[3] := IsKeyDown(KEY_C);
    Data.Bits[4] := IsKeyDown(KEY_V);
    Result := Result or Data;
  end;

  if not APort.Bits[9] then
  begin
    { $FDFE }
    Data.Bits[0] := IsKeyDown(KEY_A);
    Data.Bits[1] := IsKeyDown(KEY_S);
    Data.Bits[2] := IsKeyDown(KEY_D);
    Data.Bits[3] := IsKeyDown(KEY_F);
    Data.Bits[4] := IsKeyDown(KEY_G);
    Result := Result or Data;
  end;

  if not APort.Bits[10] then
  begin
    { $FBFE }
    Data.Bits[0] := IsKeyDown(KEY_Q);
    Data.Bits[1] := IsKeyDown(KEY_W);
    Data.Bits[2] := IsKeyDown(KEY_E);
    Data.Bits[3] := IsKeyDown(KEY_R);
    Data.Bits[4] := IsKeyDown(KEY_T);
    Result := Result or Data;
  end;

  if not APort.Bits[11] then
  begin
    { $F7FE }
    Data.Bits[0] := IsKeyDown(KEY_ONE);
    Data.Bits[1] := IsKeyDown(KEY_TWO);
    Data.Bits[2] := IsKeyDown(KEY_THREE);
    Data.Bits[3] := IsKeyDown(KEY_FOUR);
    Data.Bits[4] := IsKeyDown(KEY_FIVE);
   {
    if Joystick.Type_ = jtCursor then
      Data.Bits[4] := Data.Bits[4] or IsKeyDown(KEY_LEFT);
    }

    Result := Result or Data;
  end;

  if not APort.Bits[12] then
  begin
    { $EFFE }
    Data.Bits[0] := IsKeyDown(KEY_ZERO) or IsKeyDown(KEY_BACKSPACE);
    Data.Bits[1] := IsKeyDown(KEY_NINE);
    Data.Bits[2] := IsKeyDown(KEY_EIGHT);
    Data.Bits[3] := IsKeyDown(KEY_SEVEN);
    Data.Bits[4] := IsKeyDown(KEY_SIX);
    {
    if Joystick.Type_ = jtCursor then
    begin
      Data.Bits[0] := Data.Bits[0] or IsKeyDown(Joystick.Keys.Fire1);
      Data.Bits[2] := Data.Bits[2] or IsKeyDown(Joystick.Keys.Right);
      Data.Bits[3] := Data.Bits[3] or IsKeyDown(Joystick.Keys.Up);
      Data.Bits[4] := Data.Bits[4] or IsKeyDown(Joystick.Keys.Down);
    end;
    }

    Result := Result or Data;
  end;

  if not APort.Bits[13] then
  begin
    { $DFFE }
    Data.Bits[0] := IsKeyDown(KEY_P);
    Data.Bits[1] := IsKeyDown(KEY_O);
    Data.Bits[2] := IsKeyDown(KEY_I);
    Data.Bits[3] := IsKeyDown(KEY_U);
    Data.Bits[4] := IsKeyDown(KEY_Y);
    Result := Result or Data;
  end;

  if not APort.Bits[14] then
  begin
    { $BFFE }
    Data.Bits[0] := IsKeyDown(KEY_ENTER);
    Data.Bits[1] := IsKeyDown(KEY_L)
      or IsKeyDown(KEY_EQUAL);
    Data.Bits[2] := IsKeyDown(KEY_K)
      or (IsKeyDown(KEY_KP_ADD));
    Data.Bits[3] := IsKeyDown(KEY_J)
      or IsKeyDown(KEY_MINUS);
    Data.Bits[4] := IsKeyDown(KEY_H);
    Result := Result or Data;
  end;

  if not APort.Bits[15] then
  begin
    { $7FFE }
    Data.Bits[0] := IsKeyDown(KEY_SPACE);

    Data.Bits[1] := IsKeyDown(KEY_KP_ADD)
      or IsKeyDown(KEY_MINUS)
      or IsKeyDown(KEY_EQUAL);

    for Key in SymbolShiftKeys do
      Data.Bits[1] := Data.Bits[1] or IsKeyDown(Key);

    Data.Bits[2] := IsKeyDown(KEY_M);
    Data.Bits[3] := IsKeyDown(KEY_N);
    Data.Bits[4] := IsKeyDown(KEY_B);
    Result := Result or Data;
  end;

  Result := not Result;
end;

end.

