unit Keyboards;

{$mode unleashed}

interface

uses
  Classes, SysUtils, FGL,
  Raylib;

type
  TKeyboard = class
  private
    FHeldOver: TKeyboardKey;
    procedure BuildKeyRects;
    function GetBreakSpaceKey: TKeyboardKey;
    function GetCapsShiftKey: TKeyboardKey;
    class function GetKeyName(AKey: TKeyboardKey): String; static;
    class function GetKeyId(AKey: TKeyboardKey): String; static;
    function GetSymbolShiftKey: TKeyboardKey;
  public
    SymbolShiftKeys: TArray<TKeyboardKey>;
    CapsShiftKeys: TArray<TKeyboardKey>;
    BreakSpaceKeys: TArray<TKeyboardKey>;
    KeyRects: TFPGMap<TKeyboardKey, TRectangle>;
    property SymbolShiftKey: TKeyboardKey read GetSymbolShiftKey;
    property CapsShiftKey: TKeyboardKey read GetCapsShiftKey;
    property BreakSpaceKey: TKeyboardKey read GetBreakSpaceKey;
    class property KeyName[AKey: TKeyboardKey]: String read GetKeyName;
    { The same key written the way the config stores it - stable across
      keyboard layouts, unlike KeyName, and read back by KeyFromId. }
    class property KeyId[AKey: TKeyboardKey]: String read GetKeyId;
    class function KeyFromId(const AId: String): TKeyboardKey; static;
    class function GetKeyNames(AKeys: TArray<TKeyboardKey>): TStringArray;
    { A key still held when the OSD menu closed was meant for the menu, not for
      the machine - which starts running again that very frame, in time to read
      the ENTER that picked a game as the game's own "press any key". Poll
      reports an idle keyboard until AKey has been let go. }
    procedure SuppressUntilReleased(AKey: TKeyboardKey);
    constructor Create;
    destructor Destroy; override;
    function Poll(APort: Word): Byte;
    function GetHighlights: TArray<TRectangle>;
  end;

implementation

type
  TNamedKey = record
    Key: TKeyboardKey;
    Name: String;
  end;

const
  { Every key that does not name itself by the character it types. The table is
    read both ways - it labels a key on screen, and it is what a key binding is
    written as in the config - so a name here is part of the config format and
    has to stay put. }
  NamedKeys: array[0..51] of TNamedKey = (
    (Key: KEY_ESCAPE;        Name: 'Esc'),
    (Key: KEY_ENTER;         Name: 'Enter'),
    (Key: KEY_SPACE;         Name: 'Space'),
    (Key: KEY_BACKSPACE;     Name: 'Backspace'),
    (Key: KEY_TAB;           Name: 'Tab'),
    (Key: KEY_INSERT;        Name: 'Ins'),
    (Key: KEY_DELETE;        Name: 'Del'),
    (Key: KEY_HOME;          Name: 'Home'),
    (Key: KEY_END;           Name: 'End'),
    (Key: KEY_PAGE_UP;       Name: 'PgUp'),
    (Key: KEY_PAGE_DOWN;     Name: 'PgDn'),
    (Key: KEY_CAPS_LOCK;     Name: 'Caps Lock'),
    (Key: KEY_LEFT;          Name: 'Left'),
    (Key: KEY_RIGHT;         Name: 'Right'),
    (Key: KEY_UP;            Name: 'Up'),
    (Key: KEY_DOWN;          Name: 'Down'),
    (Key: KEY_LEFT_SHIFT;    Name: 'Left SHIFT'),
    (Key: KEY_RIGHT_SHIFT;   Name: 'Right SHIFT'),
    (Key: KEY_LEFT_CONTROL;  Name: 'Left CTRL'),
    (Key: KEY_RIGHT_CONTROL; Name: 'Right CTRL'),
    {$ifdef Darwin}
      (Key: KEY_LEFT_ALT;    Name: 'Left OPT'),
      (Key: KEY_RIGHT_ALT;   Name: 'Right OPT'),
      (Key: KEY_LEFT_SUPER;  Name: 'Left CMD'),
      (Key: KEY_RIGHT_SUPER; Name: 'Right CMD'),
    {$else}
      (Key: KEY_LEFT_ALT;    Name: 'Left ALT'),
      (Key: KEY_RIGHT_ALT;   Name: 'Right ALT'),
      (Key: KEY_LEFT_SUPER;  Name: 'Left SUPER'),
      (Key: KEY_RIGHT_SUPER; Name: 'Right SUPER'),
    {$endif}
    (Key: KEY_F1;            Name: 'F1'),
    (Key: KEY_F2;            Name: 'F2'),
    (Key: KEY_F3;            Name: 'F3'),
    (Key: KEY_F4;            Name: 'F4'),
    (Key: KEY_F5;            Name: 'F5'),
    (Key: KEY_F6;            Name: 'F6'),
    (Key: KEY_F7;            Name: 'F7'),
    (Key: KEY_F8;            Name: 'F8'),
    (Key: KEY_F9;            Name: 'F9'),
    (Key: KEY_F10;           Name: 'F10'),
    (Key: KEY_F11;           Name: 'F11'),
    (Key: KEY_F12;           Name: 'F12'),
    (Key: KEY_KP_0;          Name: 'Pad 0'),
    (Key: KEY_KP_1;          Name: 'Pad 1'),
    (Key: KEY_KP_2;          Name: 'Pad 2'),
    (Key: KEY_KP_3;          Name: 'Pad 3'),
    (Key: KEY_KP_4;          Name: 'Pad 4'),
    (Key: KEY_KP_5;          Name: 'Pad 5'),
    (Key: KEY_KP_6;          Name: 'Pad 6'),
    (Key: KEY_KP_7;          Name: 'Pad 7'),
    (Key: KEY_KP_8;          Name: 'Pad 8'),
    (Key: KEY_KP_9;          Name: 'Pad 9'),
    (Key: KEY_KP_DECIMAL;    Name: 'Pad .'),
    (Key: KEY_KP_DIVIDE;     Name: 'Pad /'),
    (Key: KEY_KP_MULTIPLY;   Name: 'Pad *'),
    (Key: KEY_KP_SUBTRACT;   Name: 'Pad -'),
    (Key: KEY_KP_ADD;        Name: 'Pad +'),
    (Key: KEY_KP_ENTER;      Name: 'Pad Enter'));

  { What an unbound control reads as, in the config and on screen. }
  NoKeyId = 'None';

{ The table entry for AKey, or -1 if the key names itself. }
function FindNamedKey(AKey: TKeyboardKey): Integer;
var
  Index: Integer;
begin
  for Index := Low(NamedKeys) to High(NamedKeys) do
    if NamedKeys[Index].Key = AKey then Exit(Index);
  Result := -1;
end;

function TKeyboard.GetBreakSpaceKey: TKeyboardKey;
begin
  Result := if Length(BreakSpaceKeys) > 0 then BreakSpaceKeys[0] else KEY_NULL;
end;

function TKeyboard.GetCapsShiftKey: TKeyboardKey;
begin
  Result := if Length(CapsShiftKeys) > 0 then CapsShiftKeys[0] else KEY_NULL;
end;

class function TKeyboard.GetKeyName(AKey: TKeyboardKey): String; static;
var
  Index: Integer;
begin
  Index := FindNamedKey(AKey);
  if Index >= 0 then
    Result := NamedKeys[Index].Name
  else
    { Whatever this key types on the layout in use, which is the name worth
      showing even though it is not the one worth storing. }
    Result := Raylib.GetKeyName(AKey);

  if Result.IsEmpty then Result := KeyId[AKey];

  Result := Result.ToUpper;
end;

class function TKeyboard.GetKeyId(AKey: TKeyboardKey): String; static;
var
  Index: Integer;
begin
  Index := FindNamedKey(AKey);
  if Index >= 0 then
    Result := NamedKeys[Index].Name
  else if (AKey > 32) and (AKey < 127) then
    { raylib's key codes are the ASCII ones for the keys that type a character,
      so the character is the key's own name. }
    Result := Chr(AKey)
  else if AKey = KEY_NULL then
    Result := NoKeyId
  else
    { Nothing readable to fall back on - a key nobody is likely to bind, kept
      round-trippable rather than dropped. }
    Result := '#' + IntToStr(AKey);
end;

class function TKeyboard.KeyFromId(const AId: String): TKeyboardKey; static;
var
  Id: String;
  Index: Integer;
begin
  Id := AId.Trim;
  Result := KEY_NULL;
  if Id.IsEmpty or SameText(Id, NoKeyId) then Exit;

  for Index := Low(NamedKeys) to High(NamedKeys) do
    if SameText(Id, NamedKeys[Index].Name) then Exit(NamedKeys[Index].Key);

  if Length(Id) = 1 then
    Result := Ord(UpCase(Id[1]))
  else if Id.StartsWith('#') then
    Result := StrToIntDef(Id.Substring(1), KEY_NULL);
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
  KeyRects := TFPGMap<TKeyboardKey, TRectangle>.Create;
  BuildKeyRects;
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

destructor TKeyboard.Destroy;
begin
  FreeAndNil(KeyRects);
end;

procedure TKeyboard.BuildKeyRects;
  function GetKeyRect(ARow, ACol: Integer): TRectangle;
  var
    BaseX: array[1..4] of Integer = (15, 63, 87, 17);
  const
    BaseY = 42;
    DX = 93;
    DY = 106;
    Width = 60;
    Height = 47;
    CSWidth = 90;
    BSWidth = 110;
    Row4Offset = 20;
  begin
    Result := RectangleCreate(
      BaseX[ARow] + (DX * (ACol - 1)),
      BaseY + (DY * (ARow - 1)),
      Width, Height);

    if ARow = 4 then
    begin
      if ACol > 1 then Result.x := Result.x + Row4Offset;
      case ACol of
         1: Result.width := CSWidth;
        10: Result.width := BSWidth;
      end;
    end;
  end;

var
  Key: TKeyboardKey;
begin
  with KeyRects do
  begin
    Clear;

    Add(KEY_ONE,   GetKeyRect(1, 1));
    Add(KEY_TWO,   GetKeyRect(1, 2));
    Add(KEY_THREE, GetKeyRect(1, 3));
    Add(KEY_FOUR,  GetKeyRect(1, 4));
    Add(KEY_FIVE,  GetKeyRect(1, 5));
    Add(KEY_SIX,   GetKeyRect(1, 6));
    Add(KEY_SEVEN, GetKeyRect(1, 7));
    Add(KEY_EIGHT, GetKeyRect(1, 8));
    Add(KEY_NINE,  GetKeyRect(1, 9));
    Add(KEY_ZERO,  GetKeyRect(1, 10));

    Add(KEY_Q, GetKeyRect(2, 1));
    Add(KEY_W, GetKeyRect(2, 2));
    Add(KEY_E, GetKeyRect(2, 3));
    Add(KEY_R, GetKeyRect(2, 4));
    Add(KEY_T, GetKeyRect(2, 5));
    Add(KEY_Y, GetKeyRect(2, 6));
    Add(KEY_U, GetKeyRect(2, 7));
    Add(KEY_I, GetKeyRect(2, 8));
    Add(KEY_O, GetKeyRect(2, 9));
    Add(KEY_P, GetKeyRect(2, 10));

    Add(KEY_A, GetKeyRect(3, 1));
    Add(KEY_S, GetKeyRect(3, 2));
    Add(KEY_D, GetKeyRect(3, 3));
    Add(KEY_F, GetKeyRect(3, 4));
    Add(KEY_G, GetKeyRect(3, 5));
    Add(KEY_H, GetKeyRect(3, 6));
    Add(KEY_J, GetKeyRect(3, 7));
    Add(KEY_K, GetKeyRect(3, 8));
    Add(KEY_L, GetKeyRect(3, 9));
    Add(KEY_ENTER, GetKeyRect(3, 10));

    for Key in CapsShiftKeys do
      Add(Key, GetKeyRect(4, 1));

    Add(KEY_Z, GetKeyRect(4, 2));
    Add(KEY_X, GetKeyRect(4, 3));
    Add(KEY_C, GetKeyRect(4, 4));
    Add(KEY_V, GetKeyRect(4, 5));
    Add(KEY_B, GetKeyRect(4, 6));
    Add(KEY_N, GetKeyRect(4, 7));
    Add(KEY_M, GetKeyRect(4, 8));

    for Key in SymbolShiftKeys do
      Add(Key, GetKeyRect(4, 9));

    Add(KEY_SPACE, GetKeyRect(4, 10));
  end;
end;

function TKeyboard.GetHighlights: TArray<TRectangle>;
var
  I: Integer;
  Key: TKeyboardKey;
begin
  Result := [];
  for I := 0 to KeyRects.Count - 1 do
    if IsKeyDown(KeyRects.Keys[I]) then
      Insert(KeyRects.Data[I], Result, Integer.MaxValue);
end;

end.

