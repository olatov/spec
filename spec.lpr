program Spec;

{$mode unleashed}

{$ifdef Darwin}
  {$linkframework Cocoa}
  {$linkframework IOKit}
{$endif}

uses
  Classes, Sysutils, CTypes, Math, IniFiles, System.IOUtils,
  Raylib, Raymath,
  Z80, Tape, Spectrum;

type
  { Ink/paper colour pair already resolved from one attribute byte, indexed by
    pixel bit: [0] = paper, [1] = ink. }
  TPixelPair = array[0..1] of TColorB;
  TAttrTable = array[0..255] of TPixelPair;
  PAttrTable = ^TAttrTable;

  { The raylib image's raw R8G8B8A8 buffer, addressed directly. }
  TPixels = array[0..(352 * 288) - 1] of TColorB;
  PPixels = ^TPixels;

  TJoystickType = (jtNone, jtKempston, jtCursor);
  TJoystick = record
    Type_: TJoystickType;
    Keys: record
      Left, Right, Up, Down, Fire1, Fire2: TKeyboardKey;
    end;
  end;

const
  StartFullscreen = True;
  ImageWidth = 352;
  ImageHeight = 288;
  ScanlineTStates = 224;
  TotalScanlines = 312;
  TStatesPerFrame = ScanlineTStates * TotalScanlines;
  FPS = 50;
  AudioFrequency = 44100;
  SamplesPerFrame = AudioFrequency div FPS;
  AudioChunkFrames = SamplesPerFrame * 5; { must stay >= the audio device's internal period size, or
    raylib pads the shortfall with raw zero bytes - which is true silence for signed
    16-bit PCM, so a shortfall now degrades to silence instead of a loud click }
  AudioHigh: CInt16 = CInt16.MaxValue;
  AudioLow: CInt16 = CInt16.MinValue;

const
  { raylib's AutomationEventType enum isn't exposed in raylib.h/raylib.pas
    (it's internal to rcore.c) - these two values are its first two entries. }
  INPUT_KEY_UP = 1;
  INPUT_KEY_DOWN = 2;

var
  Machine: TZXSpectrum48;
  { Test-automation support (opt-in via SPEC_AUTOLOAD / SPEC_SCREENSHOT_DIR
    env vars): scripts the LOAD "" ENTER keystrokes via raylib automation
    events and dumps screenshots, so tape loading can be verified without a
    real keyboard/window focus. }
  AutoLoadFrame: Int64 = -1;
  ScreenshotDir: String = '';
  PendingScreenshot: Boolean = False;
  Snapshot: String = '';
  AudioBuffer: array[0..SamplesPerFrame - 1] of CInt16;
  AudioStream: TAudioStream;
  OSD: record
    Text: String;
    Lifetime: Double;
  end;
  PrevTiming: Integer = 0;   { index of the sample bucket currently being accumulated }
  PrevT: Integer = 0;        { T-state at which that accumulation last left off }
  BucketStartT: Integer = 0; { T-state at which the current bucket began }
  BucketHigh: Integer = 0;   { T-states spent HIGH within the current bucket so far }
  AccumBuf: array[0..AudioChunkFrames - 1] of CInt16;
  AccumPos: Integer = 0;
  Joystick: TJoystick;
  {$embedstr ShaderText 'shader.fs'}

function GetQuickSaveFilename: String;
var
  Path: String = '';
begin
  Path := GetAppConfigDir(False);
  TDirectory.CreateDirectory(Path);
  Result := TPath.Combine(Path, 'quicksave.z80');
end;

procedure QuickSave;
begin
  Machine.SaveZ80(GetQuickSaveFilename);
end;

function QuickLoad: Boolean;
var
  Filename: String;
begin
  Filename := GetQuickSaveFilename;
  if not TFile.Exists(Filename) then Exit(False);

  Machine.LoadZ80(Filename);
  Result := True;
end;

{ Advances the audio-sample cursor to absolute T-state NewT, treating AudioPin as having
  held constant since the last call. Rather than snapshotting one instant per output sample
  (which aliases high-pitched beeper toggling - e.g. Wham!'s PWM-style tricks - into audible
  spurious tones), each finished bucket is written as the pin's HIGH duty cycle over its
  exact T-state span: a boxcar low-pass filter matched to the sample rate. }
function BucketBoundary(Index: Integer): Integer; inline;
begin
  Result := (Index * TStatesPerFrame) div SamplesPerFrame;
end;

procedure AdvanceAudio(NewT: Integer);
var
  NextBoundary, Duration: Integer;
begin
  while PrevTiming < SamplesPerFrame do
  begin
    NextBoundary := BucketBoundary(PrevTiming + 1);
    if NextBoundary > NewT then Break;

    if Machine.AudioPin then Inc(BucketHigh, NextBoundary - PrevT);
    Duration := NextBoundary - BucketStartT;
    AudioBuffer[PrevTiming] := CInt16(AudioLow + (BucketHigh * (Integer(AudioHigh) - AudioLow)) div Duration);

    PrevT := NextBoundary;
    BucketStartT := NextBoundary;
    BucketHigh := 0;
    Inc(PrevTiming);
  end;

  if Machine.AudioPin then Inc(BucketHigh, NewT - PrevT);
  PrevT := NewT;
end;

procedure SetOSD(AText: String; ADuration: Double = 2); forward;

procedure OnHalt(context: Pointer; state: UInt8); cdecl;
begin

end;

function OnNop(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function TrapMemRead(Address: UInt16): Byte;
begin
  Result := if (address and $C000) = 0
    then Machine.ROM[address]
    else Machine.RAM[address];
end;

procedure TrapMemWrite(Address: UInt16; Value: Byte);
begin
  if (address and $C000) = 0 then Exit; { ROM }
  Machine.RAM[address] := Value;
end;

function OnHook(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  if address = LDBytesAddress then
  begin
    HandleLoadTrap(@Machine.CPU, @TrapMemRead, @TrapMemWrite);
    SetOSD($'Loading block {CurrentBlock}/{TotalBlocks}');
    if not ScreenshotDir.IsEmpty then
      PendingScreenshot := True;
    { The Z80 core treats the hook's return value as a fresh opcode to
      dispatch immediately UNLESS it's Z80_HOOK (see hook's INSN in
      Z80.c) - returning Z80_HOOK is what tells it "the hook fully
      replaced this instruction", leaving `pc` exactly where
      HandleLoadTrap's RET simulation set it, instead of also executing
      one stray extra instruction there first. }
    Result := Z80_HOOK;
  end
  else
    { Not our trap address - this is a real (if useless) LD H,H
      instruction elsewhere; let it behave as a harmless NOP rather than
      swallowing it as Z80_HOOK, which would leave `pc` stuck unadvanced. }
    Result := Z80_NOP;
end;

procedure AutoKeyEvent(EventType: LongWord; Key: TKeyboardKey);
var
  Event: TAutomationEvent;
begin
  Event.type_ := EventType;
  Event.params[0] := Integer(Key);
  PlayAutomationEvent(Event);
end;

{ Scripts "LOAD ""ENTER" one keystroke at a time - J (LOAD keyword), then
  SYMBOL SHIFT+P twice (the BASIC editor does NOT auto-pair quotes, so both
  the opening and closing " need an explicit keypress), then ENTER. Each
  key is held for 5 frames with a 5-frame gap before the next, generous
  enough that the ROM's own keyboard debounce reliably registers it. Rel
  is frames since AutoLoadFrame. }
procedure RunAutoLoadScript(Rel: Int64);
begin
  case Rel of
    0:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_J);
    3:  AutoKeyEvent(INPUT_KEY_UP, KEY_J);
    5:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_LEFT_CONTROL);
    7:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    10: AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    12: AutoKeyEvent(INPUT_KEY_UP, KEY_LEFT_CONTROL);
    22: AutoKeyEvent(INPUT_KEY_DOWN, KEY_LEFT_CONTROL);
    24: AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    27: AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    29: AutoKeyEvent(INPUT_KEY_UP, KEY_LEFT_CONTROL);
    39: AutoKeyEvent(INPUT_KEY_DOWN, KEY_ENTER);
    42: AutoKeyEvent(INPUT_KEY_UP, KEY_ENTER);
  end;
end;

function OnMemoryRead(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := TrapMemRead(address);
  if Machine.Contended and InRange(Address, $4000, $7FFF) then Machine.Wait(1);
end;

procedure OnMemoryWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  TrapMemWrite(address, value);
  if Machine.Contended and InRange(Address, $4000, $7FFF) then Machine.Wait(1);
end;

function OnIORead(context: Pointer; address: UInt16): UInt8; cdecl;
  function PollKeyboard(AMask: Byte): Byte;
  var
    Data: Byte;
  begin
    Result := 0;
    Data := 0;

    if not AMask.Bits[0] then
    begin
      { $FEFE }
      Data.Bits[0] := IsKeyDown(KEY_LEFT_SHIFT)
        or IsKeyDown(KEY_RIGHT_SHIFT)
        or IsKeyDown(KEY_BACKSPACE);
      Data.Bits[1] := IsKeyDown(KEY_Z);
      Data.Bits[2] := IsKeyDown(KEY_X);
      Data.Bits[3] := IsKeyDown(KEY_C);
      Data.Bits[4] := IsKeyDown(KEY_V);
      Result := Result or Data;
    end;

    if not AMask.Bits[1] then
    begin
      { $FDFE }
      Data.Bits[0] := IsKeyDown(KEY_A);
      Data.Bits[1] := IsKeyDown(KEY_S);
      Data.Bits[2] := IsKeyDown(KEY_D);
      Data.Bits[3] := IsKeyDown(KEY_F);
      Data.Bits[4] := IsKeyDown(KEY_G);
      Result := Result or Data;
    end;

    if not AMask.Bits[2] then
    begin
      { $FBFE }
      Data.Bits[0] := IsKeyDown(KEY_Q);
      Data.Bits[1] := IsKeyDown(KEY_W);
      Data.Bits[2] := IsKeyDown(KEY_E);
      Data.Bits[3] := IsKeyDown(KEY_R);
      Data.Bits[4] := IsKeyDown(KEY_T);
      Result := Result or Data;
    end;

    if not AMask.Bits[3] then
    begin
      { $F7FE }
      Data.Bits[0] := IsKeyDown(KEY_ONE);
      Data.Bits[1] := IsKeyDown(KEY_TWO);
      Data.Bits[2] := IsKeyDown(KEY_THREE);
      Data.Bits[3] := IsKeyDown(KEY_FOUR);
      Data.Bits[4] := IsKeyDown(KEY_FIVE);

      if Joystick.Type_ = jtCursor then
        Data.Bits[4] := Data.Bits[4] or IsKeyDown(KEY_LEFT);

      Result := Result or Data;
    end;

    if not AMask.Bits[4] then
    begin
      { $EFFE }
      Data.Bits[0] := IsKeyDown(KEY_ZERO) or IsKeyDown(KEY_BACKSPACE);
      Data.Bits[1] := IsKeyDown(KEY_NINE);
      Data.Bits[2] := IsKeyDown(KEY_EIGHT);
      Data.Bits[3] := IsKeyDown(KEY_SEVEN);
      Data.Bits[4] := IsKeyDown(KEY_SIX);

      if Joystick.Type_ = jtCursor then
      begin
        Data.Bits[0] := Data.Bits[0] or IsKeyDown(Joystick.Keys.Fire1);
        Data.Bits[2] := Data.Bits[2] or IsKeyDown(Joystick.Keys.Right);
        Data.Bits[3] := Data.Bits[3] or IsKeyDown(Joystick.Keys.Up);
        Data.Bits[4] := Data.Bits[4] or IsKeyDown(Joystick.Keys.Down);
      end;

      Result := Result or Data;
    end;

    if not AMask.Bits[5] then
    begin
      { $DFFE }
      Data.Bits[0] := IsKeyDown(KEY_P);
      Data.Bits[1] := IsKeyDown(KEY_O);
      Data.Bits[2] := IsKeyDown(KEY_I);
      Data.Bits[3] := IsKeyDown(KEY_U);
      Data.Bits[4] := IsKeyDown(KEY_Y);
      Result := Result or Data;
    end;

    if not AMask.Bits[6] then
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

    if not AMask.Bits[7] then
    begin
      { $7FFE }
      Data.Bits[0] := IsKeyDown(KEY_SPACE);
      Data.Bits[1] := IsKeyDown(KEY_LEFT_CONTROL)
        or IsKeyDown(KEY_RIGHT_CONTROL)
        or IsKeyDown(KEY_KP_ADD)
        or IsKeyDown(KEY_MINUS)
        or IsKeyDown(KEY_EQUAL);
      Data.Bits[2] := IsKeyDown(KEY_M);
      Data.Bits[3] := IsKeyDown(KEY_N);
      Data.Bits[4] := IsKeyDown(KEY_B);
      Result := Result or Data;
    end;

    Result := not Result;
  end;

  function PollKempston: Byte;
  begin
    if Joystick.Type_ <> jtKempston then
    begin
      Result := $FF;
      Exit;
    end;

    Result := 0;
    Result.Bits[0] := IsKeyDown(Joystick.Keys.Right);
    Result.Bits[1] := IsKeyDown(Joystick.Keys.Left);
    Result.Bits[2] := IsKeyDown(Joystick.Keys.Down);
    Result.Bits[3] := IsKeyDown(Joystick.Keys.Up);
    Result.Bits[4] := IsKeyDown(Joystick.Keys.Fire1);
    Result.Bits[5] := IsKeyDown(Joystick.Keys.Fire2);
  end;

begin
  { WriteLn('IO READ addr ', IntToHex(address, 4)); }

  Result := $FF;

  if not address.Bits[0] then
    Result := Result and PollKeyboard(Hi(address));

  if not address.Bits[5] then
    Result := Result and PollKempston;
end;

procedure OnIOWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  case address.Bytes[0] of
    $FE:
      begin
        Machine.BorderColorIndex := value and %111;
        AdvanceAudio(Machine.Cycles + Machine.CPU.cycles);
        Machine.AudioPin := value.Bits[4];
      end;
  end;
end;

function OnNMIA(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { Writeln('NMIA'); }
end;

function OnINTA(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { Writeln('INTA'); }
  { /INT is deasserted on a fixed 32 T-state schedule in the main loop,
    not here - see the pulse-width model there. }
  { On real Spectrum hardware nothing drives the data bus during the
    interrupt acknowledge cycle, so it floats and reads back as $FF.
    This only matters in IM2, where it's combined with the I register
    to look up the ISR address; IM1 ignores it (always RST 38h). }
  Result := $FF;
end;

function OnINTFetch(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function OnIllegal(cpu: PZ80; opcode: UInt8): UInt8; cdecl;
begin
  Result := 0;
end;

procedure OnLDIA(context: Pointer); cdecl;
begin

end;

procedure OnLDRA(context: Pointer); cdecl;
begin

end;

procedure OnRETI(context: Pointer); cdecl;
begin

end;

procedure OnRETN(context: Pointer); cdecl;
begin

end;

procedure SetOSD(AText: String; ADuration: Double = 2);
begin
  OSD.Text := AText;
  OSD.Lifetime := GetTime + ADuration;
end;

procedure Main;
var
  Target: TRenderTexture2D;
  Image: TImage;
  Video: TTexture2D;
  Pixels: PPixels;
  I, AttrOffset, PixelIndex, LinesLoc: Integer;
  Data: Byte;
  Palette: array[0..15] of TColorB;
  { One resolved colour pair per attribute byte, per FLASH phase: the whole
    ink/paper/bright/flash decode collapses into a single table lookup. }
  AttrColors: array[0..1] of TAttrTable;
  AttrTable: PAttrTable;
  Pair: ^TPixelPair;
  Paused: Boolean = False;
  Fullscreen: Boolean = StartFullscreen;
  LinesCount: Single = 288;
  Shader: TShader;
  Curvature: Single = 7.5;
  TVMode: Integer = %0111;
  Volume: Single;
  S: String;
  Config: TIniFile;

  procedure SetVolume(AVolume: Single; K: Single = 4);
  begin
    Volume := EnsureRange(AVolume, 0, 1.0);
    SetAudioStreamVolume(AudioStream, (Exp(K * Volume) - 1) / (Exp(K) - 1));
  end;

  procedure RenderScanline(ALine: Integer); inline;
  var
    X, Y, Offset: Integer;
  begin
    Y := ALine - 16;
    if not InRange(Y, 0, ImageHeight - 1) then Exit;

    { Border }
    FillDWord(Pixels^[Y * ImageWidth], ImageWidth,
      PDWord(@Palette[Machine.BorderColorIndex])^);

    { Main }
    Y := Y - 48;
    if not InRange(Y, 0, 191) then Exit;

    { Screen layout: third, then pixel Y within the character row, then
      character row within the third. }
    Offset := 16384;
    Inc(Offset, (Y div 64) * 2048);
    Inc(Offset, ((Y mod 64) div 8) * 32);
    Inc(Offset, (Y mod 8) * 256);

    AttrOffset := 22528 + ((Y div 8) * 32);
    PixelIndex := ((Y + 48) * ImageWidth) + 48;

    for X := 0 to 31 do
    begin
      Data := Machine.RAM[Offset + X];
      Pair := @AttrTable^[Machine.RAM[AttrOffset + X]];

      Pixels^[PixelIndex + 0] := Pair^[(Data shr 7) and 1];
      Pixels^[PixelIndex + 1] := Pair^[(Data shr 6) and 1];
      Pixels^[PixelIndex + 2] := Pair^[(Data shr 5) and 1];
      Pixels^[PixelIndex + 3] := Pair^[(Data shr 4) and 1];
      Pixels^[PixelIndex + 4] := Pair^[(Data shr 3) and 1];
      Pixels^[PixelIndex + 5] := Pair^[(Data shr 2) and 1];
      Pixels^[PixelIndex + 6] := Pair^[(Data shr 1) and 1];
      Pixels^[PixelIndex + 7] := Pair^[Data and 1];

      Inc(PixelIndex, 8);
    end;
  end;

  { Resolves every attribute byte into its ink/paper colour pair, for both FLASH
    phases. Must be rerun if Palette changes. }
  procedure BuildAttrColors;
  var
    Phase, Attribute, Bright, InkIndex, PaperIndex: Integer;
  begin
    for Phase := 0 to 1 do
      for Attribute := 0 to 255 do
      begin
        Bright := (Attribute shr 6) and 1;
        InkIndex := (Attribute and %111) or (Bright shl 3);
        PaperIndex := ((Attribute shr 3) and %111) or (Bright shl 3);

        if (Attribute.Bits[7]) and (Phase = 1) then
          Swap<Integer>(InkIndex, PaperIndex);

        AttrColors[Phase][Attribute][0] := Palette[PaperIndex];
        AttrColors[Phase][Attribute][1] := Palette[InkIndex];
      end;
  end;

  procedure SetTVMode(AMode: Integer);
  var
    Value: CInt32;
  begin
    Value := IfThen(AMode.Bits[0], 1, 0);
    SetShaderValue(Shader,
      GetShaderLocation(Shader, 'enableMask'),
      @Value, SHADER_UNIFORM_INT);

    Value := IfThen(AMode.Bits[1], 1, 0);
    SetShaderValue(Shader,
      GetShaderLocation(Shader, 'enableScanlines'),
      @Value, SHADER_UNIFORM_INT);

    Value := IfThen(AMode.Bits[2], 1, 0);
    SetShaderValue(Shader,
      GetShaderLocation(Shader, 'enableCurvature'),
      @Value, SHADER_UNIFORM_INT);

    Value := IfThen(AMode.Bits[3], 1, 0);
    SetShaderValue(Shader,
      GetShaderLocation(Shader, 'enableGrayscale'),
      @Value, SHADER_UNIFORM_INT);

    SetShaderValue(Shader,
      GetShaderLocation(Shader, 'curvature'),
      @Curvature, SHADER_UNIFORM_FLOAT);
  end;

begin
  if not LoadLibrary then
    raise Exception.CreateFmt('Failed to load %s', [DefaultZ80LibPath]);

  Machine := autofree TZXSpectrum48.Create;

  Palette := [
    GetColor($000000FF),
    GetColor($0000D8FF),
    GetColor($D80000FF),
    GetColor($D800D8FF),
    GetColor($00D800FF),
    GetColor($00D8D8FF),
    GetColor($D8D800FF),
    GetColor($D8D8D8FF),

    GetColor($000000FF),
    GetColor($0000FFFF),
    GetColor($FF0000FF),
    GetColor($FF00FFFF),
    GetColor($00FF00FF),
    GetColor($00FFFFFF),
    GetColor($FFFF00FF),
    GetColor($FFFFFFFF)
  ];

  for I := 0 to 15 do
    Palette[I] := ColorContrast(Palette[I], -0.1);

  BuildAttrColors;

  ScreenshotDir := GetEnvironmentVariable('SPEC_SCREENSHOT_DIR');
  if not ScreenshotDir.IsEmpty then
    ForceDirectories(ScreenshotDir);

  with Machine.CPU do
  begin
    fetch := @OnMemoryRead;
    fetch_opcode := @OnMemoryRead;
    halt := @OnHalt;
    read := @OnMemoryRead;
    write := @OnMemoryWrite;
    hook := @OnHook;
    input := @OnIORead;
    output := @OnIOWrite;
    nop := @OnNop;
    nmia := @OnNMIA;
    inta := @OnINTA;
    int_fetch := @OnINTFetch;
    ld_i_a := @OnLDIA;
    ld_r_a := @OnLDRA;
    reti := @OnRETI;
    retn := @OnRETN;
    illegal := @OnIllegal;
  end;

  with Joystick do
  begin
    Type_ := jtKempston;
    with Joystick.Keys do
    begin
      Left := KEY_LEFT;
      Right := KEY_RIGHT;
      Up := KEY_UP;
      Down := KEY_DOWN;
      Fire1 := KEY_LEFT_ALT;
      Fire2 := KEY_RIGHT_ALT;
    end;
  end;

  Config := autofree TIniFile.Create(GetAppConfigFile(False, True));
  Fullscreen := Config.ReadBool('Window', 'Fullscreen', True);

  SetTraceLogLevel(LOG_ERROR);

  if Config.ReadBool('Window', 'HiDPI', False) then
    SetConfigFlags(FLAG_WINDOW_HIGHDPI);

  InitWindow(
    Config.ReadInteger('Window', 'Width', 720),
    Config.ReadInteger('Window', 'Height', 576),
    'Spec');

  TVMode := Config.ReadInteger('Window', 'TVMode', 7);

  SetWindowState(FLAG_WINDOW_RESIZABLE);
  ClearWindowState(FLAG_VSYNC_HINT);
  SetTargetFPS(FPS);

  if Fullscreen then
  begin
    ToggleBorderlessWindowed;
    HideCursor;
  end;

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture, TEXTURE_FILTER_BILINEAR);
  SetTextureWrap(Target.texture, TEXTURE_WRAP_CLAMP);

  Shader := LoadShaderFromMemory(Nil, @ShaderText[1]);

  LinesCount := 288 - 32;
  LinesLoc := GetShaderLocation(Shader, 'lines');
  SetShaderValue(Shader, LinesLoc, @LinesCount, SHADER_UNIFORM_FLOAT);

  SetTVMode(TVMode);

  Image := GenImageColor(ImageWidth, ImageHeight, BLACK);
  Pixels := Image.data;
  Video := LoadTextureFromImage(Image);

  InitAudioDevice;

  SetAudioStreamBufferSizeDefault(AudioChunkFrames);
  AudioStream := LoadAudioStream(AudioFrequency, 16, 1);
  SetVolume(Config.ReadFloat('Audio', 'Volume', 0.4));

  Machine.Power := True;

  if ParamCount > 0 then Snapshot := ParamStr(1);

  if not Snapshot.IsEmpty then
  begin
    if Snapshot.ToLower.EndsWith('.tap', True) then
    begin
      { Leave the ROM unpatched if the tape fails to load, so a bad
        filename doesn't silently break normal BASIC boot. }
      if LoadTAP(Snapshot) then
      begin
        Machine.ROM[LDBytesAddress] := Z80_HOOK;
        if not GetEnvironmentVariable('SPEC_AUTOLOAD').IsEmpty then
          AutoLoadFrame := 100; { give the ROM time to finish booting to BASIC first }
      end;
    end else
    begin
      if not Snapshot.ToLower.EndsWith('.z80') then Snapshot := Snapshot + '.z80';
      Machine.LoadZ80(Snapshot);
    end;
  end;

  PlayAudioStream(AudioStream);

  FillByte(AccumBuf, SizeOf(AccumBuf), 0); { 0 = silence for signed 16-bit PCM }

  for I := 1 to 3 do
    if IsAudioStreamProcessed(AudioStream) then
      UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);

  while not WindowShouldClose do
  begin
    if IsKeyPressed(KEY_F2) then
    begin
      QuickSave;
      SetOSD('Saved');
    end;

    if IsKeyPressed(KEY_F3) and QuickLoad then
      SetOSD('Loaded');

    if IsKeyPressed(KEY_F7) or IsKeyPressed(KEY_F8) then
    begin
      SetVolume(Volume
        - IfThen(IsKeyPressed(KEY_F7), 0.05, 0)
        + IfThen(IsKeyPressed(KEY_F8), 0.05, 0));
      SetOsd($'Volume: {Volume * 100:%.0f}');
    end;

    if IsKeyPressed(KEY_F9) then
    begin
      TVMode := (TVMode + 1) and $0F;
      SetTVMode(TVMode);
      SetOSD($'TV mode: {TVMode}');
    end;

    if IsKeyPressed(KEY_F6) then
    begin
      Joystick.Type_ := if Joystick.Type_ <> High(TJoystickType)
        then Succ(Joystick.Type_)
        else Low(TJoystickType);

      case Joystick.Type_ of
        jtNone: S := 'Off';
        jtKempston: S := 'Kempston';
        jtCursor: S := 'Cursor';
      end;

      SetOSD($'Joystick: {S}');
    end;

    if IsKeyPressed(KEY_F10) then Paused := not Paused;
    if IsKeyPressed(KEY_F11) then
    begin
      ToggleBorderlessWindowed;
      Fullscreen := not Fullscreen;
      if Fullscreen then
        HideCursor
      else
        ShowCursor;
    end;

    if not Paused then
    begin
      Machine.BeginFrame;

      if AutoLoadFrame >= 0 then
        RunAutoLoadScript(Int64(Machine.Frames) - AutoLoadFrame);

      AdvanceAudio(TStatesPerFrame);
      PrevTiming := 0;
      PrevT := 0;
      BucketStartT := 0;
      BucketHigh := 0;

      Move(AudioBuffer, AccumBuf[AccumPos], SamplesPerFrame * SizeOf(CInt16));
      Inc(AccumPos, SamplesPerFrame);
      if AccumPos >= AudioChunkFrames then
      begin
        if IsAudioStreamProcessed(AudioStream) then
          UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);
        AccumPos := 0;
      end;

      AttrTable := @AttrColors[Ord(Machine.FlashPhase)];

      {
        RASTER:
          VBlank: 8 lines (INT in the end of line 0)
          Top border: 56 (8 invisible + 48 visible) lines
          Main screen: 192 lines
          Bottom border: 56 lines
        TOTAL: 312 lines
      }
      for I := 1 to 312 do
      begin
        RenderScanline(Machine.CurrentScanline);
        Machine.RunScanline;
      end;

      UpdateTexture(Video, Image.data);
    end;

    BeginTextureMode(Target);
    DrawTexture(Video, 0, 0, WHITE);
    if not OSD.Text.IsEmpty then
      if GetTime < OSD.Lifetime then
        DrawText(PAnsiChar(OSD.Text), 18, 18, 16, ORANGE)
      else
        OSD.Text := '';
    EndTextureMode;

    BeginDrawing;
    ClearBackground(BLACK);
    BeginShaderMode(Shader);
    DrawTexturePro(
      Target.Texture,
      RectangleCreate(16, 16, Target.texture.width - 32, -Target.texture.height + 32),
      if (GetScreenWidth / GetScreenHeight) >= 1.333
        then RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0, GetScreenHeight * 1.333, GetScreenHeight)
        else RectangleCreate(0, (0.5 * GetScreenHeight) - (GetScreenWidth * 0.375), GetScreenWidth, GetScreenWidth * 0.75),
      Vector2Zero, 0, WHITE);
    EndShaderMode;
    { DrawFPS(10, 10); }

    EndDrawing;

    if not ScreenshotDir.IsEmpty then
    begin
      if PendingScreenshot then
      begin
        { ExportImage writes fileName verbatim - unlike TakeScreenshot, which
          silently joins it under CORE.Storage.basePath (the exe's directory)
          and so fails quietly for an arbitrary absolute output path. }
        ExportImage(Image, PAnsiChar($'{ScreenshotDir}/block-{CurrentBlock}-of-{TotalBlocks}.png'));
        PendingScreenshot := False;
      end
      else if (AutoLoadFrame >= 0) and (Machine.Frames >= QWord(AutoLoadFrame))
        and (Machine.Frames <= QWord(AutoLoadFrame) + 80) then
        ExportImage(Image, PAnsiChar($'{ScreenshotDir}/frame-{Machine.Frames}.png'))
      else if (AutoLoadFrame >= 0) and (Machine.Frames > QWord(AutoLoadFrame) + 80)
        and (Machine.Frames <= QWord(AutoLoadFrame) + 300) and ((Machine.Frames mod 10) = 0) then
        ExportImage(Image, PAnsiChar($'{ScreenshotDir}/frame-{Machine.Frames}.png'));
    end;
  end;

  StopAudioStream(AudioStream);
  UnloadAudioStream(AudioStream);
  CloseAudioDevice;

  Config.WriteBool('Window', 'Fullscreen', Fullscreen);
  if not Fullscreen then
  begin
    Config.WriteInteger('Window', 'Width', GetScreenWidth);
    Config.WriteInteger('Window', 'Height', GetScreenHeight);
  end;

  Config.WriteInteger('Window', 'TVMode', TVMode);

  Config.WriteFloat('Audio', 'Volume', Volume);

  UnloadShader(Shader);
  UnloadRenderTexture(Target);
  UnloadTexture(Video);
  UnloadImage(Image);

  CloseWindow;
end;

begin
  Main;
end.

