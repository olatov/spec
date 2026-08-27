unit main;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, CTypes, IniFiles, System.IOUtils,
  Raylib, RayMath,
  Z80, Spectrum;

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
    KBTexture: TTexture2D;
    ShowKeyboard: Boolean;
    Image: TImage;
    Video: TTexture2D;
    Shaders: array[0..2] of TShader;
    Paused: Boolean;
    TVType: Byte;
    Palette: array[0..15] of TColorB;
    AttrColors: array[0..1] of TAttrTable;
    Pixels: PPixels;
    AttrTable: PAttrTable;
    Overscan: Integer;
    property Fullscreen: Boolean read FFullscreen write SetFullscreen;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Initialize;
    procedure Run;
    procedure HandleInput;
    procedure RenderVideoFrame;
    procedure RenderAudioFrame;
    procedure SaveConfig;
  end;

const
  TVTypeColor = 0;
  TVTypeBW = 1;
  TVTypeModern = 2;

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
  {$embedstr ShaderTextColor 'shaders/shader_color.fs'}
  {$embedstr ShaderTextBW 'shaders/shader_bw.fs'}
  {$embedstr ShaderTextModern 'shaders/shader_modern.fs'}
  {$embedbytes KBLayout 'images/keyboard.png'}

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
  if FFullscreen then
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
var
  I: Integer;
begin
  inherited Destroy;

  SaveConfig;
  FreeAndNil(Config);

  UnloadAudioStream(AudioStream);
  CloseAudioDevice;

  for I := 0 to High(Shaders) do
    UnloadShader(Shaders[I]);
  UnloadRenderTexture(Target);
  UnloadTexture(Video);
  UnloadImage(Image);

  if IsTextureValid(KBTexture) then UnloadTexture(KBTexture);

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
  I: Integer;
  LinesCount: Single = 256;
  Curvature: Single = 7.0;
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
    Config.ReadInteger('Window', 'Width', 800),
    Config.ReadInteger('Window', 'Height', 600),
    'Spec');

  SetTargetFPS(FPS);
  SetWindowState(FLAG_WINDOW_RESIZABLE);
  ClearWindowState(FLAG_VSYNC_HINT);

  Fullscreen := Config.ReadBool('Window', 'Fullscreen', True);

  TVType := Config.ReadInteger('Window', 'TVType', TVTypeColor) mod Length(Shaders);
  Overscan := Config.ReadInteger('Window', 'Overscan', 16);

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture, TEXTURE_FILTER_BILINEAR);

  Shaders[TVTypeColor] := LoadShaderFromMemory(Nil, @ShaderTextColor[1]);
  Shaders[TVTypeBW] := LoadShaderFromMemory(Nil, @ShaderTextBW[1]);
  Shaders[TVTypeModern] := LoadShaderFromMemory(Nil, @ShaderTextModern[1]);

  for I := 0 to High(Shaders) do
  begin
    SetShaderValue(Shaders[I],
      GetShaderLocation(Shaders[I], 'lines'), @LinesCount, SHADER_UNIFORM_FLOAT);
    SetShaderValue(Shaders[I],
      GetShaderLocation(Shaders[I], 'curvature'), @Curvature, SHADER_UNIFORM_FLOAT);
  end;

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
  Dest: TRectangle;
begin
  Machine.Power := True;

  if ParamCount > 0 then Snapshot := ParamStr(1);

  if not Snapshot.IsEmpty then
  begin
    if Snapshot.ToLower.EndsWith('.tap', True) then
    begin
      { Leave the ROM unpatched if the tape fails to load, so a bad
        filename doesn't silently break normal BASIC boot. }

      if Machine.LoadTAP(Snapshot) then
        if Config.ReadBool('Tape', 'AutoLoad', True) or not GetEnvironmentVariable('SPEC_AUTOLOAD').IsEmpty then
          AutoLoadFrame := 100; { give the ROM time to finish booting to BASIC first }

    end else if Snapshot.ToLower.EndsWith('.wav', True) then
    begin
      { Real-time load: the ROM/turbo loader polls the EAR line; playback
        auto-starts (and auto-pauses between blocks) once LD-BYTES runs. }
      if Machine.LoadWAV(Snapshot) then
        if Config.ReadBool('Tape', 'AutoLoad', True) or not GetEnvironmentVariable('SPEC_AUTOLOAD').IsEmpty then
          AutoLoadFrame := 100;

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
      DrawTexturePRO(Video,
        RectangleCreate(0, 0, Video.width, Video.height),
        RectangleCreate(0, 0, Target.texture.width, Target.texture.height),
        Vector2Zero, 0, WHITE);
    EndTextureMode;

    BeginDrawing;
      ClearBackground(BLACK);
      BeginShaderMode(Shaders[TVType]);

      Dest := if (GetScreenWidth / GetScreenHeight) >= 1.333
        then RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0, GetScreenHeight * 1.333, GetScreenHeight)
        else RectangleCreate(0, (0.5 * GetScreenHeight) - (GetScreenWidth * 0.375), GetScreenWidth, GetScreenWidth * 0.75);

      DrawTexturePro(
        Target.Texture,
        RectangleCreate(Overscan, Overscan, Target.texture.width - (2 * Overscan), -Target.texture.height + (2 * Overscan)),
        Dest,
        Vector2Zero, 0, WHITE);
      EndShaderMode;

      if ShowKeyboard then
      begin
        Dest.height := KBTexture.height * Dest.width / KBTexture.width;
        DrawTexturePro(KBTexture,
          RectangleCreate(0, 0, KBTexture.width, KBTexture.height), Dest, Vector2Zero, 0, WHITE);
        DrawRectangleLinesEx(Dest, 1, RAYWHITE);
      end;

      if not OSD.Text.IsEmpty then
        if GetTime < OSD.Lifetime then
          DrawText(PAnsiChar(OSD.Text), Trunc(Dest.x) + 20, Trunc(Dest.y), GetScreenHeight div 12, ORANGE)
        else
          OSD.Text := '';
    EndDrawing;
  end;

  StopAudioStream(AudioStream);
end;

procedure TApplication.HandleInput;
var
  S: String;
  Buffer: TImage;
begin
  if IsKeyPressed(KEY_F1) then
  begin
    ShowKeyboard := not ShowKeyboard;
    if ShowKeyboard then
    begin
      Buffer := LoadImageFromMemory('.png', KBLayout, SizeOf(KBLayout));
      KBTexture := LoadTextureFromImage(Buffer);
      SetTextureFilter(KBTexture, TEXTURE_FILTER_BILINEAR);
      UnloadImage(Buffer);
    end
    else
      UnloadTexture(KBTexture);
  end;

  if IsKeyPressed(KEY_F2) then
  begin
    QuickSave;
    SetOSD('Saved');
  end;

  if IsKeyPressed(KEY_F3) and QuickLoad then
    SetOSD('Loaded');

  if IsKeyPressed(KEY_F4) or IsKeyPressedRepeat(KEY_F4) then Dec(Overscan);
  if IsKeyPressed(KEY_F5) or IsKeyPressedRepeat(KEY_F5) then Inc(Overscan);

  if IsKeyPressed(KEY_F7) or IsKeyPressed(KEY_F8) then
  begin
    SetVolume(AudioVolume
      - IfThen(IsKeyPressed(KEY_F7), 0.05, 0)
      + IfThen(IsKeyPressed(KEY_F8), 0.05, 0));
    SetOsd($'Volume: {AudioVolume * 100:%.0f}');
  end;

  if IsKeyPressed(KEY_F9) then
  begin
    TVType := (TVType + 1) mod Length(Shaders);

    case TVType of
      TVTypeColor: S := 'Colour';
      TVTypeBW: S := 'BW';
      TVTypeModern: S := 'Modern';
    end;

    SetOSD($'TV type: {S}');
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

  if IsKeyPressed(KEY_F12) and Machine.WavLoaded then
  begin
    if Machine.TapePlaying then
    begin
      Machine.TapePause;
      SetOSD('Tape paused');
    end
    else
    begin
      Machine.TapePlay;
      SetOSD($'Tape playing  {Machine.TapePositionSeconds:%.0f}/{Machine.TapeLengthSeconds:%.0f}s');
    end;
  end;
end;

procedure TApplication.RenderVideoFrame;
  procedure RenderScanline(ALine: Integer); inline;
  var
    X, Y, Offset, AttrOffset, PixelIndex: Integer;
    Data: Byte;
    Pair: ^TPixelPair;
  begin
    Y := ALine;
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
      Top border: 48 lines
      Main screen: 192 lines
      Bottom border: 48 lines
      Retrace + "invisible" border: 24 lines
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

  Config.WriteInteger('Window', 'TVType', TVType);
  Config.WriteInteger('Widnow', 'Overscan', Overscan);

  Config.WriteFloat('Audio', 'Volume', AudioVolume);
end;

end.

