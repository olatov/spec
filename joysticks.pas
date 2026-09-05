unit Joysticks;

{$mode unleashed}

interface

uses
  Classes, SysUtils, IniFiles,
  Raylib, Inputs;

type
  { The six things a joystick can report. }
  TJoystickControl = (jcLeft, jcRight, jcUp, jcDown, jcFire1, jcFire2);
  TJoystickBindings = array[TJoystickControl] of TControlBinding;

  { The interface a game reads its stick through. What a player presses to work
    the stick is not part of that - they have one set of controls, and switching
    between a Kempston and a Cursor interface must not change them - so the
    bindings are shared by every joystick rather than owned by one. }
  TJoystick = class abstract
  private
    function GetDown: Boolean;
    function GetFire1: Boolean;
    function GetFire2: Boolean;
    function GetLeft: Boolean;
    function GetName: String; virtual;
    function GetRight: Boolean;
    function GetUp: Boolean;
    class function GamepadSection(const AName: String): String; static;
  public
    property Name: String read GetName;
    class var Bindings: TJoystickBindings;
    { The pad whose bindings are the ones now in Bindings, or '' where no pad
      has been seen this run. What SaveBindings writes the pad half under -
      and why it writes nothing when no pad has turned up, rather than filing
      the built-in defaults under some pad that was never here. }
    class var GamepadProfile: String;
    { The built-in bindings, also what an absent config setting falls back to. }
    class procedure ResetBindings; static;
    class procedure ResetKeyBindings; static;
    class procedure ResetGamepadBindings; static;
    { True while anything bound to AControl is held - the key, the pad button
      or the stick, whichever the player reached for. }
    class function IsDown(AControl: TJoystickControl): Boolean; static;
    { Binds ASource to AControl in place of whatever of its own kind was there,
      and takes it off every other control, so one press can never mean two
      directions at once. }
    class procedure Bind(AControl: TJoystickControl; const ASource: TInputSource); static;
    class procedure Unbind(AControl: TJoystickControl); static;
    { The binding as the menu shows it. }
    class function Describe(AControl: TJoystickControl): String; static;
    { The keys, which belong to the player and stay put whatever is plugged in.
      Reading them falls back to the pre-profile config format, so a setup made
      before bindings had a section of their own survives the upgrade. }
    class procedure LoadBindings(F: TIniFile); static;
    class procedure SaveBindings(F: TIniFile); static;
    { The pad half, which belongs to that particular pad and is kept under its
      name - so two pads can be bound differently and neither forgets when the
      other is plugged in. A pad the file has never seen gets the defaults. }
    class procedure LoadGamepadBindings(F: TIniFile; const AName: String); static;
    class procedure SaveGamepadBindings(F: TIniFile); static;
    function Poll(APort: Word): Byte; virtual;
    property Left: Boolean read GetLeft;
    property Right: Boolean read GetRight;
    property Up: Boolean read GetUp;
    property Down: Boolean read GetDown;
    property Fire1: Boolean read GetFire1;
    property Fire2: Boolean read GetFire2;
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

const
  { The section the keys go in - part of the config format, like the control
    names that are the keys within it. }
  BindingsSection = 'Bindings';
  { Where the pad's own half goes, one section per pad. }
  GamepadSectionPrefix = 'Bindings:';

  { What the keys were called before they had a section: six integers, raylib
    key codes, in among the rest of the joystick settings. Read once, to carry
    an existing setup over, and cleared out on the next save. }
  LegacySection = 'Joystick';
  LegacyKeyNames: array[TJoystickControl] of String =
    ('LeftKey', 'RightKey', 'UpKey', 'DownKey', 'Fire1Key', 'Fire2Key');

class procedure TJoystick.ResetKeyBindings; static;
begin
  Bind(jcLeft, TInputSource.FromKey(KEY_LEFT));
  Bind(jcRight, TInputSource.FromKey(KEY_RIGHT));
  Bind(jcUp, TInputSource.FromKey(KEY_UP));
  Bind(jcDown, TInputSource.FromKey(KEY_DOWN));
  {$ifdef Darwin}
    Bind(jcFire1, TInputSource.FromKey(KEY_LEFT_SUPER));
    Bind(jcFire2, TInputSource.FromKey(KEY_RIGHT_SUPER));
  {$else}
    Bind(jcFire1, TInputSource.FromKey(KEY_LEFT_ALT));
    Bind(jcFire2, TInputSource.FromKey(KEY_RIGHT_ALT));
  {$endif}
end;

class procedure TJoystick.ResetGamepadBindings; static;
begin
  { The D-pad and the left stick both. Which of the two a pad reports a
    direction on is the pad's business rather than the player's, and a pad
    that has only one of them is common enough that binding only the other
    reads as the pad not working at all. }
  Bind(jcLeft, TInputSource.FromButton(GAMEPAD_BUTTON_LEFT_FACE_LEFT));
  Bind(jcRight, TInputSource.FromButton(GAMEPAD_BUTTON_LEFT_FACE_RIGHT));
  Bind(jcUp, TInputSource.FromButton(GAMEPAD_BUTTON_LEFT_FACE_UP));
  Bind(jcDown, TInputSource.FromButton(GAMEPAD_BUTTON_LEFT_FACE_DOWN));
  Bind(jcFire1, TInputSource.FromButton(GAMEPAD_BUTTON_RIGHT_FACE_DOWN));
  Bind(jcFire2, TInputSource.FromButton(GAMEPAD_BUTTON_RIGHT_FACE_LEFT));

  Bind(jcLeft, TInputSource.FromAxis(GAMEPAD_AXIS_LEFT_X, -1));
  Bind(jcRight, TInputSource.FromAxis(GAMEPAD_AXIS_LEFT_X, 1));
  Bind(jcUp, TInputSource.FromAxis(GAMEPAD_AXIS_LEFT_Y, -1));
  Bind(jcDown, TInputSource.FromAxis(GAMEPAD_AXIS_LEFT_Y, 1));
  { Fire is a button on every pad worth the name. }
  ClearBinding(Bindings[jcFire1], [ikAxis]);
  ClearBinding(Bindings[jcFire2], [ikAxis]);
end;

class procedure TJoystick.ResetBindings; static;
begin
  ResetKeyBindings;
  ResetGamepadBindings;
end;

class function TJoystick.IsDown(AControl: TJoystickControl): Boolean; static;
begin
  Result := BindingIsDown(Bindings[AControl]);
end;

class procedure TJoystick.Bind(AControl: TJoystickControl; const ASource: TInputSource); static;
var
  Control: TJoystickControl;
begin
  if ASource.Kind = ikNone then Exit;

  for Control := Low(TJoystickControl) to High(TJoystickControl) do
    if (Control <> AControl) and SameSource(Bindings[Control][ASource.Kind], ASource) then
      Bindings[Control][ASource.Kind] := TInputSource.None;

  SetSource(Bindings[AControl], ASource);
end;

class procedure TJoystick.Unbind(AControl: TJoystickControl); static;
begin
  ClearBinding(Bindings[AControl], AllKinds);
end;

class function TJoystick.Describe(AControl: TJoystickControl): String; static;
begin
  Result := BindingDescription(Bindings[AControl], AllKinds);
  if Result.IsEmpty then Result := 'none';
end;

class function TJoystick.GamepadSection(const AName: String): String; static;
begin
  Result := GamepadSectionPrefix + AName;
end;

class procedure TJoystick.LoadBindings(F: TIniFile); static;
var
  Control: TJoystickControl;
begin
  ResetKeyBindings;

  if F.SectionExists(BindingsSection) then
    for Control := Low(TJoystickControl) to High(TJoystickControl) do
      { An absent line keeps the default; a line with nothing after it is a
        control the player has deliberately left unbound. }
      ApplyBinding(Bindings[Control],
        F.ReadString(BindingsSection, JoystickControlNames[Control],
          BindingToString(Bindings[Control], KeyKinds)),
        KeyKinds)
  else
    for Control := Low(TJoystickControl) to High(TJoystickControl) do
      if F.ValueExists(LegacySection, LegacyKeyNames[Control]) then
      begin
        ClearBinding(Bindings[Control], KeyKinds);
        SetSource(Bindings[Control], TInputSource.FromKey(
          F.ReadInteger(LegacySection, LegacyKeyNames[Control], KEY_NULL)));
      end;
end;

class procedure TJoystick.SaveBindings(F: TIniFile); static;
var
  Control: TJoystickControl;
begin
  for Control := Low(TJoystickControl) to High(TJoystickControl) do
  begin
    F.WriteString(BindingsSection, JoystickControlNames[Control],
      BindingToString(Bindings[Control], KeyKinds));
    { The old six integers say the same thing in a format nothing reads any
      more, and two answers to one question in a hand-editable file is one
      too many. }
    F.DeleteKey(LegacySection, LegacyKeyNames[Control]);
  end;

  SaveGamepadBindings(F);
end;

class procedure TJoystick.LoadGamepadBindings(F: TIniFile; const AName: String); static;
var
  Control: TJoystickControl;
  Section: String;
begin
  ResetGamepadBindings;
  GamepadProfile := AName;
  if AName.IsEmpty then Exit;

  Section := GamepadSection(AName);
  if not F.SectionExists(Section) then Exit;

  for Control := Low(TJoystickControl) to High(TJoystickControl) do
    ApplyBinding(Bindings[Control],
      F.ReadString(Section, JoystickControlNames[Control],
        BindingToString(Bindings[Control], GamepadKinds)),
      GamepadKinds);
end;

class procedure TJoystick.SaveGamepadBindings(F: TIniFile); static;
var
  Control: TJoystickControl;
  Section: String;
begin
  { Nothing to file these under, and nothing worth filing: no pad has been
    here to bind them. }
  if GamepadProfile.IsEmpty then Exit;

  Section := GamepadSection(GamepadProfile);
  for Control := Low(TJoystickControl) to High(TJoystickControl) do
    F.WriteString(Section, JoystickControlNames[Control],
      BindingToString(Bindings[Control], GamepadKinds));
end;

function TJoystick.Poll(APort: Word): Byte;
begin
  Result := 0;
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
  Result := 'Joystick';
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
