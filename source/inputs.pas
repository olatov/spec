unit Inputs;

{$mode unleashed}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, System.IOUtils,
  Raylib, Keyboards;

type
  { The three things a player can press, and the nothing they leave behind
    when a binding is cleared. }
  TInputKind = (ikNone, ikKey, ikButton, ikAxis);
  TInputKinds = set of TInputKind;

  { One of them, whichever it is. Written into the config and read back as
    text, so the names ToString puts in a file are part of the config format
    and have to stay put. }
  TInputSource = record
    Kind: TInputKind;
    { The key, the button or the axis - whichever Kind says this is. }
    Code: Integer;
    { Axes only: which end of the axis counts as pressed. }
    Sign: Shortint;
    function IsDown: Boolean;
    { What the config stores: stable across keyboard layouts and readable by
      anyone editing the file by hand. }
    function ToString: String;
    { What the menu shows, which for a key is whatever that key types here. }
    function Description: String;
    class function FromKey(AKey: TKeyboardKey): TInputSource; static;
    class function FromButton(AButton: TGamepadButton): TInputSource; static;
    class function FromAxis(AAxis: TGamepadAxis; ASign: Shortint): TInputSource; static;
    class function Parse(const AText: String): TInputSource; static;
    class function None: TInputSource; static;
  end;

  { Everything bound to one control - at most one input of each kind, so that
    a key, a button and a stick can all work it at once and re-teaching one of
    them leaves the other two alone. }
  TControlBinding = array[TInputKind] of TInputSource;

const
  { Every kind a pad can supply, for the calls that take a set. }
  GamepadKinds = [ikButton, ikAxis];
  KeyKinds = [ikKey];
  AllKinds = [ikKey, ikButton, ikAxis];

  { Highest button and axis raylib will report, from its own enumerations. }
  LastButton = GAMEPAD_BUTTON_RIGHT_THUMB;
  LastAxis = GAMEPAD_AXIS_RIGHT_TRIGGER;

{ Whether two sources are the same press. }
function SameSource(const A, B: TInputSource): Boolean;
{ True while any of the binding's inputs is held. }
function BindingIsDown(const ABinding: TControlBinding): Boolean;
{ The binding as the config stores it, kinds outside AKinds left out - which
  is how the keys and the pad end up in different sections of the file. }
function BindingToString(const ABinding: TControlBinding; AKinds: TInputKinds): String;
{ The binding as the menu shows it. }
function BindingDescription(const ABinding: TControlBinding; AKinds: TInputKinds): String;
{ Clears every kind in AKinds, then puts back whatever AText names of them.
  A kind outside AKinds is neither read nor disturbed. }
procedure ApplyBinding(var ABinding: TControlBinding; const AText: String;
  AKinds: TInputKinds);
{ Puts ASource in, replacing whatever was bound of the same kind. }
procedure SetSource(var ABinding: TControlBinding; const ASource: TInputSource);
procedure ClearBinding(var ABinding: TControlBinding; AKinds: TInputKinds);

type
  TGamepadNotify = reference to procedure(const AName: String);

  { Which physical pad is being read - kept apart from what the bindings mean,
    since the two change for different reasons. Pads are plugged in and pulled
    out while the emulator runs, so this is rescanned as it goes rather than
    settled at startup: Update does the rescanning and wants calling once a
    frame. }
  TGamepad = class
  private
    class var FIndex: Integer;
    class var FName: String;
    class var FNextScan: Double;
    class var FSuppressed: array[0..LastButton] of Boolean;
    class function Find: Integer; static;
    class function NameOf(AIndex: Integer): String; static;
  public
    { The pad to prefer wherever it turns up, which the last one used is
      written back to. Unplugging a pad and putting it back - in another
      socket, or beside a second pad - therefore gets the same one back. }
    class var PreferredName: String;
    { How far a stick has to be pushed before the direction counts as down. }
    class var Deadzone: Single;
    { Fires whenever the pad in use changes, with '' for none left. }
    class var OnChanged: TGamepadNotify;
    class property Index: Integer read FIndex;
    class property Name: String read FName;
    class function Available: Boolean; static;
    { Picks up pads that have arrived and drops ones that have gone. }
    class procedure Update; static;
    { Teaches raylib the buttons of pads it does not already know. Silently
      does nothing where the file is absent, which is the normal case. }
    class procedure LoadMappings(const AFilename: String); static;
    class function IsButtonDown(AButton: TGamepadButton): Boolean; static;
    { Makes every button now held read as up until it has been let go of.
      What the menu closing does with the button that closed it, which is
      otherwise still down when the machine starts running again the same
      frame and reads it as fire. }
    class procedure SuppressHeld; static;
    { -1, 0 or 1: which way the axis is pushed, past the deadzone. }
    class function AxisSign(AAxis: TGamepadAxis): Shortint; static;
    class function IsAxisDown(AAxis: TGamepadAxis; ASign: Shortint): Boolean; static;
  end;

  { What the player does to the menu with a pad. }
  TPadAction = (paUp, paDown, paPageUp, paPageDown, paSelect, paBack, paMenu);

  { Menu navigation from the pad.

    Its bindings are fixed rather than configurable: they are how a player
    holding nothing but a pad reaches the page where bindings are configured,
    so they have to work before anything has been set up.

    Update must run once a frame, whether the menu is open or not - both
    because paMenu is what opens it, and because Pressed only reports what
    Update worked out, so that reading an action twice in one frame, or not at
    all, cannot upset the repeat. }
  TPadNavigation = class
  private
    class var FWasDown: array[TPadAction] of Boolean;
    class var FRepeatAt: array[TPadAction] of Double;
    class var FPressed: array[TPadAction] of Boolean;
    class function IsDown(AAction: TPadAction): Boolean; static;
  public
    class procedure Update; static;
    { True on the frame the action was pressed, and again while it is held for
      the actions that move about a page - raylib has no repeat of its own for
      a pad. Choosing and leaving never repeat. }
    class function Pressed(AAction: TPadAction): Boolean; static;
    { Takes this frame's presses away from everything that has not read them
      yet - what a page does when it has claimed the press for itself, so that
      binding START to fire does not also close the menu on the way out. }
    class procedure Consume; static;
  end;

  { What a page waiting to be told what to bind reads each frame.

    Arm and then Poll, rather than raylib's own "was pressed": the button that
    opened the page is still held, and on the desktop backend raylib reports a
    held button as the last one pressed on every frame - so a capture that
    trusted it would bind that button the instant the page appeared. Nothing
    here counts until it has been seen released. }
  TInputCapture = class
  private
    class var FButtonArmed: array[0..LastButton] of Boolean;
    class var FAxisArmed: array[0..LastAxis] of Boolean;
  public
    { Called as the page opens: whatever is already held is not an answer. }
    class procedure Arm; static;
    { The first input pressed since Arm, or None while the player has not
      pressed anything yet. }
    class function Poll: TInputSource; static;
  end;

implementation

const
  { raylib stops looking at its own MAX_GAMEPADS, which is below this in every
    build of it. }
  MaxPads = 8;
  { Seconds between full rescans while the pad in use is still answering. }
  ScanInterval = 1;
  { Half over is far enough to mean it on a worn stick, and not so far that a
    pad with a short throw cannot reach it. }
  DefaultDeadzone = 0.5;

  { How long a direction has to be held before it starts repeating, and how
    fast it repeats after that - a list is read at one speed and crossed at
    another. }
  RepeatDelay = 0.4;
  RepeatInterval = 0.08;
  { The rest choose or leave, and doing either twice is never what was meant. }
  RepeatingActions = [paUp, paDown, paPageUp, paPageDown];

  { What the prefix in front of a source says it is. }
  KeyPrefix = 'key';
  ButtonPrefix = 'pad';
  AxisPrefix = 'axis';

  { How a binding's inputs are laid out - one way for the file, another for
    the screen, where they read as alternatives rather than as a list. }
  ConfigSeparator = ', ';
  DisplaySeparator = ' / ';

  { Named by where the button sits rather than by what is printed on it: the
    same button is A on one pad and Cross on another, but it is the bottom of
    the right-hand four on both. }
  ButtonNames: array[0..LastButton] of String = (
    'None',
    'DPAD_UP', 'DPAD_RIGHT', 'DPAD_DOWN', 'DPAD_LEFT',
    'FACE_UP', 'FACE_RIGHT', 'FACE_DOWN', 'FACE_LEFT',
    'L1', 'L2', 'R1', 'R2',
    'SELECT', 'GUIDE', 'START',
    'LSTICK', 'RSTICK');

  AxisNames: array[0..LastAxis] of String = (
    'LEFT_X', 'LEFT_Y', 'RIGHT_X', 'RIGHT_Y', 'LEFT_TRIGGER', 'RIGHT_TRIGGER');

{ Codes outside the tables are kept round-trippable rather than dropped, the
  same way an unnameable key is - a pad raylib grows a button for should not
  quietly lose the binding of anyone who got there first. }
function ButtonName(AButton: TGamepadButton): String;
begin
  if (AButton >= 0) and (AButton <= LastButton) then
    Result := ButtonNames[AButton]
  else
    Result := '#' + IntToStr(AButton);
end;

function ButtonFromName(const AName: String): TGamepadButton;
var
  I: Integer;
begin
  for I := 0 to LastButton do
    if SameText(AName, ButtonNames[I]) then Exit(I);

  if AName.StartsWith('#') then
    Result := StrToIntDef(AName.Substring(1), GAMEPAD_BUTTON_UNKNOWN)
  else
    Result := GAMEPAD_BUTTON_UNKNOWN;
end;

{ Which end of an axis the binding means, as the config writes it and the
  menu shows it. }
function SignChar(ASign: Shortint): String;
begin
  Result := if ASign < 0 then '-' else '+';
end;

function AxisName(AAxis: TGamepadAxis): String;
begin
  if (AAxis >= 0) and (AAxis <= LastAxis) then
    Result := AxisNames[AAxis]
  else
    Result := '#' + IntToStr(AAxis);
end;

function AxisFromName(const AName: String): TGamepadAxis;
var
  I: Integer;
begin
  for I := 0 to LastAxis do
    if SameText(AName, AxisNames[I]) then Exit(I);

  if AName.StartsWith('#') then
    Result := StrToIntDef(AName.Substring(1), -1)
  else
    Result := -1;
end;

class function TInputSource.None: TInputSource; static;
begin
  Result.Kind := ikNone;
  Result.Code := 0;
  Result.Sign := 0;
end;

class function TInputSource.FromKey(AKey: TKeyboardKey): TInputSource; static;
begin
  Result := None;
  { KEY_NULL is how the keyboard says nothing, so it binds nothing. }
  if AKey = KEY_NULL then Exit;
  Result.Kind := ikKey;
  Result.Code := AKey;
end;

class function TInputSource.FromButton(AButton: TGamepadButton): TInputSource; static;
begin
  Result := None;
  if AButton = GAMEPAD_BUTTON_UNKNOWN then Exit;
  Result.Kind := ikButton;
  Result.Code := AButton;
end;

class function TInputSource.FromAxis(AAxis: TGamepadAxis; ASign: Shortint): TInputSource; static;
begin
  Result := None;
  if (AAxis < 0) or (ASign = 0) then Exit;
  Result.Kind := ikAxis;
  Result.Code := AAxis;
  Result.Sign := ASign;
end;

function TInputSource.IsDown: Boolean;
begin
  case Kind of
    ikKey: Result := IsKeyDown(Code);
    ikButton: Result := TGamepad.IsButtonDown(Code);
    ikAxis: Result := TGamepad.IsAxisDown(Code, Sign);
  else
    Result := False;
  end;
end;

function TInputSource.ToString: String;
begin
  case Kind of
    ikKey: Result := $'{KeyPrefix}:{TKeyboard.KeyId[Code]}';
    ikButton: Result := $'{ButtonPrefix}:{ButtonName(Code)}';
    ikAxis: Result := $'{AxisPrefix}:{AxisName(Code)}{SignChar(Sign)}';
  else
    Result := '';
  end;
end;

function TInputSource.Description: String;
begin
  case Kind of
    { The name of the key as this keyboard has it, which is the one the player
      is looking at - unlike the layout-independent name the config keeps. }
    ikKey: Result := TKeyboard.KeyName[Code];
    ikButton: Result := ButtonName(Code);
    ikAxis: Result := $'{AxisName(Code)}{SignChar(Sign)}';
  else
    Result := '';
  end;
end;

class function TInputSource.Parse(const AText: String): TInputSource; static;
var
  Text, Prefix, Body: String;
  Sign: Shortint;
  P: Integer;
begin
  Result := None;

  Text := AText.Trim;
  P := Pos(':', Text);
  if P = 0 then Exit;

  Prefix := LowerCase(Copy(Text, 1, P - 1)).Trim;
  Body := Copy(Text, P + 1, MaxInt).Trim;
  if Body.IsEmpty then Exit;

  case Prefix of
    KeyPrefix: Result := FromKey(TKeyboard.KeyFromId(Body));
    ButtonPrefix: Result := FromButton(ButtonFromName(Body));
    AxisPrefix:
      begin
        { The direction is the last character, and an axis without one names
          no direction and so binds nothing. }
        case Body[Length(Body)] of
          '-': Sign := -1;
          '+': Sign := 1;
        else
          Exit;
        end;
        Result := FromAxis(AxisFromName(Copy(Body, 1, Length(Body) - 1)), Sign);
      end;
  end;
end;

function SameSource(const A, B: TInputSource): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Code = B.Code) and (A.Sign = B.Sign);
end;

function BindingIsDown(const ABinding: TControlBinding): Boolean;
var
  Kind: TInputKind;
begin
  for Kind in AllKinds do
    if ABinding[Kind].IsDown then Exit(True);

  Result := False;
end;

{ Both joiners walk the kinds in order, so a binding always reads out the same
  way round however it was taught. }
function BindingToString(const ABinding: TControlBinding; AKinds: TInputKinds): String;
var
  Kind: TInputKind;
begin
  Result := '';
  for Kind in AKinds do
    if ABinding[Kind].Kind <> ikNone then
    begin
      if not Result.IsEmpty then Result := Result + ConfigSeparator;
      Result := Result + ABinding[Kind].ToString;
    end;
end;

function BindingDescription(const ABinding: TControlBinding; AKinds: TInputKinds): String;
var
  Kind: TInputKind;
begin
  Result := '';
  for Kind in AKinds do
    if ABinding[Kind].Kind <> ikNone then
    begin
      if not Result.IsEmpty then Result := Result + DisplaySeparator;
      Result := Result + ABinding[Kind].Description;
    end;
end;

procedure ClearBinding(var ABinding: TControlBinding; AKinds: TInputKinds);
var
  Kind: TInputKind;
begin
  for Kind in AKinds do ABinding[Kind] := TInputSource.None;
end;

procedure SetSource(var ABinding: TControlBinding; const ASource: TInputSource);
begin
  if ASource.Kind <> ikNone then ABinding[ASource.Kind] := ASource;
end;

procedure ApplyBinding(var ABinding: TControlBinding; const AText: String;
  AKinds: TInputKinds);
var
  Part: String;
  Source: TInputSource;
begin
  ClearBinding(ABinding, AKinds);

  { A line naming two inputs of one kind keeps the last of them - there is
    only one slot per kind to put them in. }
  for Part in AText.Split([',']) do
  begin
    Source := TInputSource.Parse(Part);
    if Source.Kind in AKinds then SetSource(ABinding, Source);
  end;
end;

class function TGamepad.NameOf(AIndex: Integer): String; static;
var
  P: PAnsiChar;
begin
  P := GetGamepadName(AIndex);
  { Trimmed because drivers pad the name out, and a name with trailing spaces
    is one an ini file hands back short of them - which would stop the
    remembered pad ever matching itself again. }
  Result := if Assigned(P) then String(P).Trim else '';
end;

class function TGamepad.Find: Integer; static;
var
  I: Integer;
begin
  { The remembered pad wins wherever it turns up, so a second pad joining
    cannot take player one away from the pad already in the player's hands. }
  if not PreferredName.IsEmpty then
    for I := 0 to MaxPads - 1 do
      if IsGamepadAvailable(I) and (NameOf(I) = PreferredName) then Exit(I);

  for I := 0 to MaxPads - 1 do
    if IsGamepadAvailable(I) then Exit(I);

  Result := -1;
end;

class function TGamepad.Available: Boolean; static;
begin
  Result := FIndex >= 0;
end;

class procedure TGamepad.Update; static;
var
  Found: Integer;
  T: Double;
begin
  T := GetTime;
  { A pad that is still answering is only looked past now and then - just often
    enough to notice the remembered one coming back - while one that has gone
    is replaced on the frame it goes. }
  if Available and IsGamepadAvailable(FIndex) and (T < FNextScan) then Exit;
  FNextScan := T + ScanInterval;

  Found := Find;
  { Same index and same name is the same pad: nothing to announce. }
  if (Found = FIndex) and ((Found < 0) or (NameOf(Found) = FName)) then Exit;

  FIndex := Found;
  FName := if Available then NameOf(FIndex) else '';
  { A pad going away is not a reason to forget it - that is the one it should
    come back as. }
  if not FName.IsEmpty then PreferredName := FName;

  TraceLog(LOG_INFO, PChar(if Available
    then $'GAMEPAD: [{FIndex}] {FName}'
    else 'GAMEPAD: none'));

  if Assigned(OnChanged) then OnChanged(FName);
end;

class procedure TGamepad.LoadMappings(const AFilename: String); static;
var
  Path, Text: String;
  Count: Integer;
begin
  { Looked for beside the binary as well as in the working directory, since a
    database shipped with the emulator is not something the player put there. }
  Path := AFilename;
  if not TFile.Exists(Path) then
    Path := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), AFilename);
  if not TFile.Exists(Path) then Exit;

  Text := TFile.ReadAllText(Path);
  if Text.IsEmpty then Exit;

  { Without a mapping for the pad, raylib reports whatever button order the
    driver happens to use, and the bindings land on the wrong buttons - which
    is most of what makes one pad work and the next one not. }
  Count := SetGamepadMappings(PAnsiChar(Text));
  TraceLog(LOG_INFO, PChar($'GAMEPAD: {Count} mappings applied from {Path}'));
end;

class function TGamepad.IsButtonDown(AButton: TGamepadButton): Boolean; static;
begin
  Result := Available and (AButton <> GAMEPAD_BUTTON_UNKNOWN)
    and Raylib.IsGamepadButtonDown(FIndex, AButton);

  { Buttons past the table are ones raylib has grown since and nothing has
    bound on purpose; they are read, but never held over. }
  if (AButton < 0) or (AButton > LastButton) then Exit;

  if not Result then
    FSuppressed[AButton] := False
  else if FSuppressed[AButton] then
    Result := False;
end;

class procedure TGamepad.SuppressHeld; static;
var
  I: Integer;
begin
  { Asked of raylib rather than of IsButtonDown, which would read a button
    that is already being held over as up and so let it go again. }
  for I := 0 to LastButton do
    FSuppressed[I] := Available and Raylib.IsGamepadButtonDown(FIndex, I);
end;

class function TGamepad.AxisSign(AAxis: TGamepadAxis): Shortint; static;
var
  Value: Single;
begin
  Result := 0;
  if not Available or (AAxis < 0) then Exit;

  Value := GetGamepadAxisMovement(FIndex, AAxis);
  if Value > Deadzone then Result := 1
  else if Value < -Deadzone then Result := -1;
end;

class function TGamepad.IsAxisDown(AAxis: TGamepadAxis; ASign: Shortint): Boolean; static;
begin
  Result := (ASign <> 0) and (AxisSign(AAxis) = ASign);
end;

class function TPadNavigation.IsDown(AAction: TPadAction): Boolean; static;
begin
  case AAction of
    { The stick moves about a list as well as the D-pad, since which of the
      two a pad has is the pad's business. }
    paUp: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_LEFT_FACE_UP)
      or TGamepad.IsAxisDown(GAMEPAD_AXIS_LEFT_Y, -1);
    paDown: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_LEFT_FACE_DOWN)
      or TGamepad.IsAxisDown(GAMEPAD_AXIS_LEFT_Y, 1);
    paPageUp: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_LEFT_TRIGGER_1);
    paPageDown: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_RIGHT_TRIGGER_1);
    paSelect: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_RIGHT_FACE_DOWN);
    paBack: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_RIGHT_FACE_RIGHT);
    paMenu: Result := TGamepad.IsButtonDown(GAMEPAD_BUTTON_MIDDLE_RIGHT);
  end;
end;

class procedure TPadNavigation.Update; static;
var
  Action: TPadAction;
  T: Double;
begin
  T := GetTime;

  for Action := Low(TPadAction) to High(TPadAction) do
  begin
    FPressed[Action] := False;

    if not IsDown(Action) then
    begin
      FWasDown[Action] := False;
      Continue;
    end;

    if not FWasDown[Action] then
    begin
      FWasDown[Action] := True;
      FRepeatAt[Action] := T + RepeatDelay;
      FPressed[Action] := True;
    end
    else if (Action in RepeatingActions) and (T >= FRepeatAt[Action]) then
    begin
      FRepeatAt[Action] := T + RepeatInterval;
      FPressed[Action] := True;
    end;
  end;
end;

class function TPadNavigation.Pressed(AAction: TPadAction): Boolean; static;
begin
  Result := FPressed[AAction];
end;

class procedure TPadNavigation.Consume; static;
var
  Action: TPadAction;
begin
  for Action := Low(TPadAction) to High(TPadAction) do FPressed[Action] := False;
end;

class procedure TInputCapture.Arm; static;
var
  I: Integer;
begin
  for I := 0 to LastButton do FButtonArmed[I] := not TGamepad.IsButtonDown(I);
  { A trigger rests at one end of its travel rather than in the middle, so it
    starts out disarmed and arms itself the moment it is let go. }
  for I := 0 to LastAxis do FAxisArmed[I] := TGamepad.AxisSign(I) = 0;

  { The keystroke that asked for this page is still in the queue, and would
    otherwise be read as the answer to it. }
  while GetKeyPressed <> KEY_NULL do ;
end;

class function TInputCapture.Poll: TInputSource; static;
var
  I: Integer;
  Key: TKeyboardKey;
  Sign: Shortint;
begin
  Key := GetKeyPressed;
  if Key <> KEY_NULL then Exit(TInputSource.FromKey(Key));

  for I := 1 to LastButton do
    if not TGamepad.IsButtonDown(I) then
      FButtonArmed[I] := True
    else if FButtonArmed[I] then
      Exit(TInputSource.FromButton(I));

  for I := 0 to LastAxis do
  begin
    Sign := TGamepad.AxisSign(I);
    if Sign = 0 then
      FAxisArmed[I] := True
    else if FAxisArmed[I] then
      Exit(TInputSource.FromAxis(I, Sign));
  end;

  Result := TInputSource.None;
end;

initialization
  { No pad until Update has looked for one - index 0 is a real pad, so the
    zero a class var starts life with cannot stand for "none". }
  TGamepad.FIndex := -1;
  TGamepad.Deadzone := DefaultDeadzone;

end.
