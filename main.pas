unit main;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, CTypes, IniFiles, System.IOUtils,
  Raylib, RayMath,
  Z80, Spectrum, Tape;

type
  TApplication = class(TComponent)
  private
    FFullscreen: Boolean;
    Config: TIniFile;
    procedure AdvanceAudio(NewT: Integer);
    function QuickLoad: Boolean;
    procedure QuickSave;
    procedure SetFullscreen(AValue: Boolean);
    procedure SetVolume(AVolume: Single; K: Single = 4);
  public
    Machine: TZXSpectrum48;
    AudioStream: TAudioStream;
    AudioVolume: Single;
    Target: TRenderTexture2D;
    Image: TImage;
    Video: TTexture2D;
    Shader: TShader;
    Paused: Boolean;
    TVMode: Byte;
    Palette: array[0..15] of TColorB;
    AttrColors: array[0..1] of TAttrTable;
    Pixels: PPixels;
    AttrTable: PAttrTable;
    property Fullscreen: Boolean read FFullscreen write SetFullscreen;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Initialize;
    procedure Run;
    procedure HandleInput;
    procedure RenderVideoFrame;
    procedure RenderAudioFrame;
    procedure SaveConfig;
    procedure SetTVMode(AMode: Integer);
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

  { raylib's AutomationEventType enum isn't exposed in raylib.h/raylib.pas
    (it's internal to rcore.c) - these two values are its first two entries. }
  INPUT_KEY_UP = 1;
  INPUT_KEY_DOWN = 2;

var
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
  {$embedstr ShaderText 'shader.fs'}

implementation

function GetQuickSaveFilename: String;
var
  Path: String = '';
begin
  Path := GetAppConfigDir(False);
  TDirectory.CreateDirectory(Path);
  Result := TPath.Combine(Path, 'quicksave.z80');
end;

procedure TApplication.QuickSave;
begin
  Machine.SaveZ80(GetQuickSaveFilename);
end;

procedure TApplication.SetFullscreen(AValue: Boolean);
begin
  if FFullscreen = AValue then Exit;
  FFullscreen := AValue;

  ToggleBorderlessWindowed;
  if Fullscreen then
    HideCursor
  else
    ShowCursor;
end;

function TApplication.QuickLoad: Boolean;
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

procedure TApplication.AdvanceAudio(NewT: Integer);
  function BucketBoundary(Index: Integer): Integer; inline;
  begin
    Result := (Index * TStatesPerFrame) div SamplesPerFrame;
  end;

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

procedure SetOSD(AText: String; ADuration: Double = 2);
begin
  OSD.Text := AText;
  OSD.Lifetime := GetTime + ADuration;
end;

constructor TApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Machine := TZXSpectrum48.Create;
  Config := TIniFile.Create(GetAppConfigFile(False, True));
end;

destructor TApplication.Destroy;
begin
  inherited Destroy;

  SaveConfig;
  FreeAndNil(Config);

  UnloadAudioStream(AudioStream);
  CloseAudioDevice;

  UnloadShader(Shader);
  UnloadRenderTexture(Target);
  UnloadTexture(Video);
  UnloadImage(Image);

  CloseWindow;

  FreeAndNil(Machine);
end;

procedure TApplication.Initialize;
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

var
  LinesLoc: Integer;
  LinesCount: Single = 256;
begin
  SetTraceLogLevel(LOG_ERROR);

  if not LoadLibrary then
    raise Exception.CreateFmt('Failed to load %s', [DefaultZ80LibPath]);

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

  BuildAttrColors;

  Machine.AdvanceAudio := @AdvanceAudio;

  if Config.ReadBool('Window', 'HiDPI', False) then
    SetConfigFlags(FLAG_WINDOW_HIGHDPI);

  InitWindow(
    Config.ReadInteger('Window', 'Width', 720),
    Config.ReadInteger('Window', 'Height', 576),
    'Spec');

  SetTargetFPS(FPS);
  SetWindowState(FLAG_WINDOW_RESIZABLE);
  ClearWindowState(FLAG_VSYNC_HINT);

  Fullscreen := Config.ReadBool('Window', 'Fullscreen', True);

  TVMode := Config.ReadInteger('Window', 'TVMode', 7);

  if Fullscreen then
  begin
    ToggleBorderlessWindowed;
    HideCursor;
  end;

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture, TEXTURE_FILTER_BILINEAR);
  SetTextureWrap(Target.texture, TEXTURE_WRAP_CLAMP);

  Shader := LoadShaderFromMemory(Nil, @ShaderText[1]);

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
end;

procedure TApplication.SetVolume(AVolume: Single; K: Single = 4);
begin
  AudioVolume := EnsureRange(AVolume, 0, 1.0);
  SetAudioStreamVolume(AudioStream, (Exp(K * AudioVolume) - 1) / (Exp(K) - 1));
end;

procedure TApplication.Run;
var
  I: Integer;
  Paused: Boolean = False;
begin
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
    HandleInput;

    if not Paused then
    begin
      RenderVideoFrame;
      RenderAudioFrame;
    end;

    UpdateTexture(Video, Image.data);

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
    EndDrawing;
  end;

  StopAudioStream(AudioStream);
end;

procedure TApplication.HandleInput;
var
  S: String;
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
    SetVolume(AudioVolume
      - IfThen(IsKeyPressed(KEY_F7), 0.05, 0)
      + IfThen(IsKeyPressed(KEY_F8), 0.05, 0));
    SetOsd($'Volume: {AudioVolume * 100:%.0f}');
  end;

  if IsKeyPressed(KEY_F9) then
  begin
    TVMode := (TVMode + 1) and $0F;
    SetTVMode(TVMode);
    SetOSD($'TV mode: {TVMode}');
  end;

  if IsKeyPressed(KEY_F6) then
  begin
    Machine.Joystick.Type_ := if Machine.Joystick.Type_ <> High(TJoystickType)
      then Succ(Machine.Joystick.Type_)
      else Low(TJoystickType);

    case Machine.Joystick.Type_ of
      jtNone: S := 'Off';
      jtKempston: S := 'Kempston';
      jtCursor: S := 'Cursor';
    end;

    SetOSD($'Joystick: {S}');
  end;

  if IsKeyPressed(KEY_F10) then Paused := not Paused;
  if IsKeyPressed(KEY_F11) then Fullscreen := not Fullscreen;
end;

procedure TApplication.SetTVMode(AMode: Integer);
var
  Value: CInt32;
  Curvature: Single = 7.0;
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

procedure TApplication.RenderVideoFrame;
  procedure RenderScanline(ALine: Integer); inline;
  var
    X, Y, Offset, AttrOffset, PixelIndex: Integer;
    Data: Byte;
    Pair: ^TPixelPair;
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

var
  I: Integer;
begin
  Machine.BeginFrame;
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
end;

procedure TApplication.RenderAudioFrame;
begin
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
end;

procedure TApplication.SaveConfig;
begin
  Config.WriteBool('Window', 'Fullscreen', Fullscreen);
  if not Fullscreen then
  begin
    Config.WriteInteger('Window', 'Width', GetScreenWidth);
    Config.WriteInteger('Window', 'Height', GetScreenHeight);
  end;

  Config.WriteInteger('Window', 'TVMode', TVMode);

  Config.WriteFloat('Audio', 'Volume', AudioVolume);
end;

end.

