unit Keyboards;

{$mode unleashed}

interface

uses
  Classes, SysUtils,
  Raylib;

type
  TKeyboard = class
  private
    FHeldOver: TKeyboardKey;
    function GetBreakSpaceKey: TKeyboardKey;
    function GetCapsShiftKey: TKeyboardKey;
    class function GetKeyName(AKey: TKeyboardKey): String; static;
    function GetSymbolShiftKey: TKeyboardKey;
  public
    SymbolShiftKeys: TArray<TKeyboardKey>;
    CapsShiftKeys: TArray<TKeyboardKey>;
    BreakSpaceKeys: TArray<TKeyboardKey>;
    property SymbolShiftKey: TKeyboardKey read GetSymbolShiftKey;
    property CapsShiftKey: TKeyboardKey read GetCapsShiftKey;
    property BreakSpaceKey: TKeyboardKey read GetBreakSpaceKey;
    class property KeyName[AKey: TKeyboardKey]: String read GetKeyName;
    class function GetKeyNames(AKeys: TArray<TKeyboardKey>): TStringArray;
    { A key still held when the OSD menu closed was meant for the menu, not for
      the machine - which starts running again that very frame, in time to read
      the ENTER that picked a game as the game's own "press any key". Poll
      reports an idle keyboard until AKey has been let go. }
    procedure SuppressUntilReleased(AKey: TKeyboardKey);
    constructor Create;
    function Poll(APort: Word): Byte;
  end;

implementation

function TKeyboard.GetBreakSpaceKey: TKeyboardKey;
begin
  Result := if Length(BreakSpaceKeys) > 0 then BreakSpaceKeys[0] else KEY_NULL;
end;

function TKeyboard.GetCapsShiftKey: TKeyboardKey;
begin
  Result := if Length(CapsShiftKeys) > 0 then CapsShiftKeys[0] else KEY_NULL;
end;

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
    {$ifdef Darwin}
      KEY_LEFT_ALT: Result := 'Left OPT';
      KEY_RIGHT_ALT: Result := 'Right OPT';
      KEY_LEFT_SUPER: Result := 'Left CMD';
      KEY_RIGHT_SUPER: Result := 'Right CMD';
    {$else}
      KEY_LEFT_ALT: Result := 'Left ALT';
      KEY_RIGHT_ALT: Result := 'Right ALT';
    {$endif}
  else
    Result := Raylib.GetKeyName(AKey);
  end;

  Result := Result.ToUpper;
end;

function TKeyboard.GetSymbolShiftKey: TKeyboardKey;
begin
  Result := if Length(SymbolShiftKeys) > 0 then SymbolShiftKeys[0] else KEY_NULL;
end;

class function TKeyboard.GetKeyNames(AKeys: TArray<TKeyboardKey>): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(AKeys));
  for I := 0 to High(AKeys) do
    Result[I] := KeyName[AKeys[I]];
end;

procedure TKeyboard.SuppressUntilReleased(AKey: TKeyboardKey);
begin
  FHeldOver := AKey;
end;

constructor TKeyboard.Create;
begin
  FHeldOver := KEY_NULL;
  CapsShiftKeys := [KEY_LEFT_SHIFT, KEY_RIGHT_SHIFT];
  SymbolShiftKeys :=
    {$ifdef Darwin}
      [KEY_RIGHT_ALT, KEY_LEFT_ALT];
    {$else}
      [KEY_RIGHT_CONTROL, KEY_LEFT_CONTROL];
    {$endif}
  BreakSpaceKeys := [KEY_SPACE];
end;

function TKeyboard.Poll(APort: Word): Byte;
var
  Data: Integer;
  Key: TKeyboardKey;
begin
  if APort.Bits[0] then Exit($FF);

  { $FF is what an idle keyboard reads as - the machine is deaf, rather than
    seeing something else, until the menu's keystroke is over. Nothing else in
    the port read is touched, so the tape signal keeps its timing. }
  if FHeldOver <> KEY_NULL then
    if IsKeyDown(FHeldOver) then Exit($FF) else FHeldOver := KEY_NULL;

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

