unit main;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, CTypes, IniFiles, System.IOUtils,
  Raylib, RayMath,
  Z80, Spectrum, OSDMenu, Keyboards;

type
  TApplication = class(TComponent)
  private
    FFullscreen: Boolean;
    Config: TIniFile;
    FMuted: Boolean;
    procedure AdvanceAudio(NewT: Integer);
    function BuildMenu: TMenu;
    function GetPaused: Boolean;
    procedure SetMuted(AValue: Boolean);
    procedure TapeSaved(const AFilename: String);
    function QuickLoad: Boolean;
    procedure QuickSave;
    function SaveDir: String;
    function SnapshotFiles: TStringArray;
    function ResolveSaveName(const AName: String): String;
    function DefaultSaveName: String;
    procedure DescribeSaveName(AItem: TEditMenuItem);
    function SaveSnapshot(const AName: String; out AError: String): Boolean;
    function IsLoadable(const AFilename: String): Boolean;
    function EntriesOf(const APath: String; ADirectories: Boolean): TStringArray;
    procedure BrowseFiles(AItem: TFileMenuItem);
    function LoadFile(const AFilename: String; out AError: String): Boolean;
    procedure SetFullscreen(AValue: Boolean);
    procedure SetVolume(AVolume: Single; K: Single = 4);
  public
    Machine: TZXSpectrum48;
    AudioStream: TAudioStream;
    AudioVolume: Single;
    Target: TRenderTexture2D;
    KBTexture: TTexture2D;
    ShowKeyboard: Boolean;
    ShowMenu: Boolean;
    Image: TImage;
    Video: TTexture2D;
    Menu: TMenu;
    SavePath: String;
    BrowsePath: String;   { folder the Load browser last showed }
    Shaders: array[0..2] of TShader;
    TapeSound: Boolean;   { [Tape] Sound - play tape noise through the speaker }
    TVType: Byte;
    Palette: array[0..15] of TColorB;
    AttrColors: array[0..1] of TAttrTable;
    Pixels: PPixels;
    AttrTable: PAttrTable;
    Overscan: Integer;
    QuitRequested: Boolean;
    { Frame T-state the border has been painted up to. The ULA lays the border
      down in real time, so it is filled in lazily: whenever the colour is
      about to change (and once at the end of the frame) everything the beam
      has covered since the last catch-up is painted in the outgoing colour. }
    BorderT: Integer;
    procedure PaintBorderUntil(AT: Integer);
    procedure RunFrame;
    property Muted: Boolean read FMuted write SetMuted;
    property Paused: Boolean read GetPaused;
    property Fullscreen: Boolean read FFullscreen write SetFullscreen;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Initialize;
    procedure Run;
    procedure HandleInput;
    procedure RenderVideoFrame;
    procedure RenderAudioFrame;
    procedure SaveConfig;
    procedure OnBorderChange(AIndex: TZXColorIndex; ACycles: Integer);
  end;

const
  TVTypeColor = 0;
  TVTypeBW = 1;
  TVTypeModern = 2;

  ImageWidth = 352;
  ImageHeight = 288;
  ScanlineTStates = 224;
  TotalScanlines = 312;

  { Visible window inside the raster. Rows above/below the screen band are
    border across their whole width. }
  ScreenLeft = 48;
  ScreenTop = 48;
  ScreenRight = ScreenLeft + 256;
  ScreenBottom = ScreenTop + 192;

  { The ULA emits two pixels per T-state, so a 224 T-state line is 448 pixel
    slots wide: 48 left border, 256 display, 48 right border, then 96 slots of
    horizontal blanking that never reach the image. }
  SlotsPerScanline = ScanlineTStates * 2;

  { T-states from the start of a visible row's left border to the start of that
    row's display area. The left border of row N is therefore drawn during the
    tail of line N-1. Nudge this to slide the border image horizontally against
    the screen. }
  BorderPhaseT = 24;
  TStatesPerFrame = ScanlineTStates * TotalScanlines;
  FPS = 50;
  AudioFrequency = 44100;
  SamplesPerFrame = AudioFrequency div FPS;
  AudioChunkFrames = SamplesPerFrame * 5; { must stay >= the audio device's internal period size, or
    raylib pads the shortfall with raw zero bytes - which is true silence for signed
    16-bit PCM, so a shortfall now degrades to silence instead of a loud click }
  AudioHigh: CInt16 = CInt16.MaxValue;
  AudioLow: CInt16 = CInt16.MinValue;

  { Share of the mixed output given to the tape while it plays (see TapeSound).
    Loud enough to hear the blocks go by without drowning a loader's own beeper
    effects. }
  TapeMixPercent = 45;

  { raylib's AutomationEventType enum isn't exposed in raylib.h/raylib.pas
    (it's internal to rcore.c) - these two values are its first two entries. }
  INPUT_KEY_UP = 1;
  INPUT_KEY_DOWN = 2;
  TVTypeNames: array[0..2] of String = ('Colour', 'BW', 'Modern');

  { What the file browser offers and LoadFile knows how to open. Anything else
    is left out of the list rather than failing once it is picked. }
  LoadableExtensions: array[0..2] of String = ('.z80', '.tap', '.wav');

var
  { Test-automation support (opt-in via SPEC_AUTOLOAD / SPEC_AUTOSAVE env
    vars): scripts the LOAD or SAVE keystrokes via raylib automation events,
    so tape loading and saving can be verified without a real keyboard or
    window focus. }
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
  BucketTapeHigh: Integer = 0; { same, for the tape signal (see TapeSound) }
  AccumBuf: array[0..AudioChunkFrames - 1] of CInt16;
  AccumPos: Integer = 0;
  {$embedstr ShaderTextColor 'shaders/shader_color.fs'}
  {$embedstr ShaderTextBW 'shaders/shader_bw.fs'}
  {$embedstr ShaderTextModern 'shaders/shader_modern.fs'}
  {$embedbytes KBLayout 'images/keyboard.png'}

implementation

procedure SetOSD(AText: String; ADuration: Double = 2); forward;
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
  Filename := TPath.Combine(SavePath, 'quicksave.z80');
  if not TFile.Exists(Filename) then Exit(False);

  Machine.LoadZ80(Filename);
  Result := True;
end;

procedure TApplication.QuickSave;
begin
  Machine.SaveZ80(TPath.Combine(SavePath, 'quicksave.z80'));
end;

{ Where named snapshots live. An unset [Files] SavePath means "next to the
  emulator", i.e. wherever it was started from. }
function TApplication.SaveDir: String;
begin
  Result := if SavePath.IsEmpty then GetCurrentDir else SavePath;
end;

{ Bare names of the snapshots already in SaveDir, sorted. }
function TApplication.SnapshotFiles: TStringArray;
var
  Names: TStringList;
  Filename: String;
begin
  Names := TStringList.Create;
  try
    try
      for Filename in TDirectory.GetFiles(SaveDir, '*.z80') do
        Names.Add(TPath.GetFileName(Filename));
    except
      { unreadable folder - the dialog simply lists nothing }
    end;

    Names.Sort;
    Result := Names.ToStringArray;
  finally
    Names.Free;
  end;
end;

{ Turns what was typed into a bare '<name>.z80' inside SaveDir, or '' if there
  is nothing usable in it. Any directory part is dropped rather than honoured:
  the field names a save, it does not navigate. }
function TApplication.ResolveSaveName(const AName: String): String;
begin
  Result := TPath.GetFileName(AName.Trim);
  if Result.IsEmpty then Exit;
  if not Result.ToLower.EndsWith('.z80') then Result := Result + '.z80';
end;

{ The name the Save field opens on: the loaded snapshot's or tape's own name,
  numbered up so a second save of the same game doesn't land on the first. }
function TApplication.DefaultSaveName: String;
var
  Base, Candidate: String;
  Suffix: Integer = 0;
begin
  Base := TPath.GetFileNameWithoutExtension(Snapshot);
  if Base.IsEmpty then Base := 'snapshot';

  Candidate := Base;
  while TFile.Exists(TPath.Combine(SaveDir, Candidate + '.z80')) do
  begin
    Inc(Suffix);
    Candidate := $'{Base}-{Suffix}';
  end;

  Result := Candidate;
end;

{ Keeps the Save field's warning and its list of existing snapshots in step
  with what has been typed so far. }
procedure TApplication.DescribeSaveName(AItem: TEditMenuItem);
var
  Files: TStringArray;
  Shown, I: Integer;
begin
  if TFile.Exists(TPath.Combine(SaveDir, ResolveSaveName(AItem.Value))) then
    AItem.Warning := 'A file of that name will be overwritten';

  Files := SnapshotFiles;
  Shown := Min(Length(Files), 4);

  AItem.Notes := [$'Folder: {SaveDir}'];
  if Length(Files) > 0 then
  begin
    AItem.Notes := AItem.Notes + [''] + ['Already there:'];
    for I := 0 to Shown - 1 do
      AItem.Notes := AItem.Notes + ['  ' + Files[I]];
    if Length(Files) > Shown then
      AItem.Notes := AItem.Notes + [$'  ... and {Length(Files) - Shown} more'];
  end;
end;

{ Writes the machine's state under a typed-in name. Anything the user types is
  taken as a plain file name in SaveDir - a path they type is not honoured. }
function TApplication.SaveSnapshot(const AName: String; out AError: String): Boolean;
var
  Filename: String;
begin
  AError := '';
  Filename := ResolveSaveName(AName);
  if Filename.IsEmpty then
  begin
    AError := 'Type a file name';
    Exit(False);
  end;

  try
    Machine.SaveZ80(TPath.Combine(SaveDir, Filename));
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit(False);
    end;
  end;

  SetOSD($'Saved {Filename}');
  Result := True;
end;

function TApplication.IsLoadable(const AFilename: String): Boolean;
var
  Extension, Candidate: String;
begin
  Extension := TPath.GetExtension(AFilename).ToLower;
  for Candidate in LoadableExtensions do
    if Candidate = Extension then Exit(True);
  Result := False;
end;

{ Bare names of the subfolders of APath, or of the files in it the emulator can
  open, sorted and case-insensitive. An unreadable folder simply comes back
  empty - the browser shows it as such rather than refusing to open. }
function TApplication.EntriesOf(const APath: String; ADirectories: Boolean): TStringArray;
var
  Names: TStringList;
  Entry, Folder: String;
begin
  Names := TStringList.Create;
  try
    try
      if ADirectories then
        for Entry in TDirectory.GetDirectories(APath) do
        begin
          Folder := TPath.GetFileName(ExcludeTrailingPathDelimiter(Entry));
          if not Folder.StartsWith('.') then Names.Add(Folder);   { no dot-folders }
        end
      else
        for Entry in TDirectory.GetFiles(APath) do
          if IsLoadable(Entry) then Names.Add(TPath.GetFileName(Entry));
    except
      { unreadable folder }
    end;

    Names.Sort;
    Result := Names.ToStringArray;
  finally
    Names.Free;
  end;
end;

{ Fills the browser page for the folder it is showing: the way up, then the
  subfolders, then the loadable files. Every entry carries its full path in
  Data, so the two handlers below are shared by all of them - closures must
  not capture a loop variable. }
procedure TApplication.BrowseFiles(AItem: TFileMenuItem);
var
  Entry, Parent: String;
  Navigate, Open: TMenuItemNotify;
  Count: Integer = 0;
begin
  Navigate := procedure(Sender: TMenuItem)
    begin
      (Sender.Parent as TFileMenuItem).Browse(Sender.Data);
    end;

  Open := procedure(Sender: TMenuItem)
    var
      Error: String;
    begin
      if LoadFile(Sender.Data, Error) then
      begin
        SetOSD($'Loaded {TPath.GetFileName(Sender.Data)}');
        Sender.Menu.Close;   { frees Sender - nothing may follow }
      end
      else
        Sender.Parent.Warning := $'{TPath.GetFileName(Sender.Data)}: {Error}';
    end;

  BrowsePath := AItem.Path;   { where the browser reopens next time }

  Parent := TPath.GetDirectoryName(ExcludeTrailingPathDelimiter(AItem.Path));
  if not Parent.IsEmpty and (Parent <> AItem.Path) then
    AItem.AddItem('[..]', '', Navigate).Data := Parent;

  for Entry in EntriesOf(AItem.Path, True) do
  begin
    AItem.AddItem($'[{Entry}]', '', Navigate).Data := TPath.Combine(AItem.Path, Entry);
    Inc(Count);
  end;

  for Entry in EntriesOf(AItem.Path, False) do
  begin
    AItem.AddItem(Entry, '', Open).Data := TPath.Combine(AItem.Path, Entry);
    Inc(Count);
  end;

  if Count = 0 then AItem.AddItem('(nothing to load here)');
end;

{ Opens whatever kind of file this is. A snapshot simply becomes the machine's
  state; a tape is inserted and the machine rewound to a bare BASIC prompt, so
  the scripted LOAD "" is typed into the ROM's editor and not into whatever
  happened to be running. }
function TApplication.LoadFile(const AFilename: String; out AError: String): Boolean;
var
  Extension: String;
  Tape: Boolean;
begin
  AError := '';
  Result := False;

  if not TFile.Exists(AFilename) then
  begin
    AError := 'File not found';
    Exit;
  end;

  Extension := TPath.GetExtension(AFilename).ToLower;
  Tape := (Extension = '.tap') or (Extension = '.wav');

  try
    if Extension = '.tap' then
      Result := Machine.LoadTAP(AFilename)
    else if Extension = '.wav' then
      { Real-time load: the ROM/turbo loader polls the EAR line; playback
        auto-starts (and auto-pauses between blocks) once LD-BYTES runs. }
      Result := Machine.LoadWAV(AFilename)
    else
    begin
      Machine.LoadZ80(AFilename);
      Result := True;
    end;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit(False);
    end;
  end;

  if not Result then
  begin
    { Leave the ROM unpatched if the tape fails to load, so a bad file doesn't
      silently break normal BASIC boot. }
    AError := 'Not a readable ' + Extension.Substring(1).ToUpper + ' file';
    Exit;
  end;

  Snapshot := AFilename;   { the Save field takes its default name from here }

  if Tape then
  begin
    Machine.Reset;
    if Config.ReadBool('Tape', 'AutoLoad', True)
      or not GetEnvironmentVariable('SPEC_AUTOLOAD').IsEmpty then
      AutoLoadFrame := 100;   { give the ROM time to finish booting to BASIC first }
  end;
end;


{ Advances the audio-sample cursor to absolute T-state NewT, treating AudioPin as having
  held constant since the last call. Rather than snapshotting one instant per output sample
  (which aliases high-pitched beeper toggling - e.g. Wham!'s PWM-style tricks - into audible
  spurious tones), each finished bucket is written as the pin's HIGH duty cycle over its
  exact T-state span: a boxcar low-pass filter matched to the sample rate.

  When TapeSound is on and a tape is moving - a WAV playing into EAR, or a SAVE driving
  MIC - that signal's duty cycle over the same span is blended in. The real machine's
  amplifier hears both, which is why loading and saving screech; SAVE in particular never
  touches the speaker bit, so this mix is the only thing that makes it audible. Mixing by
  weight (rather than summing) keeps the result inside the bucket duration, so the sample
  can never clip; with the tape idle the beeper keeps the full weight and the output is
  bit-identical to before. }

procedure TApplication.AdvanceAudio(NewT: Integer);
  function BucketBoundary(Index: Integer): Integer; inline;
  begin
    Result := (Index * TStatesPerFrame) div SamplesPerFrame;
  end;

var
  NextBoundary, Duration, High: Integer;
  Mixing: Boolean;
begin
  Mixing := TapeSound and (Machine.TapePlaying or Machine.Saving);

  while PrevTiming < SamplesPerFrame do
  begin
    NextBoundary := BucketBoundary(PrevTiming + 1);
    if NextBoundary > NewT then Break;

    if Machine.AudioPin then Inc(BucketHigh, NextBoundary - PrevT);
    if Mixing then Inc(BucketTapeHigh, Machine.TapeHighTStates(PrevT, NextBoundary));

    High := if Mixing
      then (BucketHigh * (100 - TapeMixPercent) + BucketTapeHigh * TapeMixPercent) div 100
      else BucketHigh;

    Duration := NextBoundary - BucketStartT;
    AudioBuffer[PrevTiming] := CInt16(AudioLow + (High * (Integer(AudioHigh) - AudioLow)) div Duration);

    PrevT := NextBoundary;
    BucketStartT := NextBoundary;
    BucketHigh := 0;
    BucketTapeHigh := 0;
    Inc(PrevTiming);
  end;

  if Machine.AudioPin then Inc(BucketHigh, NewT - PrevT);
  if Mixing then Inc(BucketTapeHigh, Machine.TapeHighTStates(PrevT, NewT));
  PrevT := NewT;
end;

procedure TApplication.TapeSaved(const AFilename: String);
begin
  SetOSD($'Saved to {AFilename}', 4);
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

{ Types "1 REM" ENTER to get a non-empty program, then SAVE "t" ENTER and the
  keypress the ROM waits for. The name is not optional - SAVE "" is rejected -
  and an empty program would save a degenerate zero-length data block. }
procedure RunAutoSaveScript(Rel: Int64);
begin
  case Rel of
    0:   AutoKeyEvent(INPUT_KEY_DOWN, KEY_ONE);
    3:   AutoKeyEvent(INPUT_KEY_UP, KEY_ONE);
    8:   AutoKeyEvent(INPUT_KEY_DOWN, KEY_E);      { REM }
    11:  AutoKeyEvent(INPUT_KEY_UP, KEY_E);
    20:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_ENTER);
    23:  AutoKeyEvent(INPUT_KEY_UP, KEY_ENTER);

    35:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_S);      { SAVE }
    38:  AutoKeyEvent(INPUT_KEY_UP, KEY_S);
    40:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_LEFT_CONTROL);
    42:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    45:  AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    47:  AutoKeyEvent(INPUT_KEY_UP, KEY_LEFT_CONTROL);
    57:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_T);
    60:  AutoKeyEvent(INPUT_KEY_UP, KEY_T);
    70:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_LEFT_CONTROL);
    72:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    75:  AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    77:  AutoKeyEvent(INPUT_KEY_UP, KEY_LEFT_CONTROL);
    87:  AutoKeyEvent(INPUT_KEY_DOWN, KEY_ENTER);
    90:  AutoKeyEvent(INPUT_KEY_UP, KEY_ENTER);
    { "Start tape, then press any key." }
    120: AutoKeyEvent(INPUT_KEY_DOWN, KEY_ENTER);
    123: AutoKeyEvent(INPUT_KEY_UP, KEY_ENTER);
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
  Machine.BorderChange := @OnBorderChange;

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
  TapeSound := Config.ReadBool('Tape', 'Sound', True);
  Machine.SaveToWav := Config.ReadBool('Tape', 'Save', True);
  Machine.OnTapeSaved := @TapeSaved;

  SavePath := Config.ReadString('Files', 'SavePath', '');
  BrowsePath := SaveDir;

  Machine.JoystickIndex := Config.ReadInteger('Joystick', 'Index', 2);
  if Machine.JoystickIndex >= Machine.Joysticks.Count then
    Machine.JoystickIndex := 0;

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
  Muted := Config.ReadBool('Audio', 'Muted', False);
end;

procedure TApplication.SetVolume(AVolume: Single; K: Single = 4);
begin
  AudioVolume := EnsureRange(AVolume, 0, 1.0);
  SetAudioStreamVolume(AudioStream, (Exp(K * AudioVolume) - 1) / (Exp(K) - 1));
end;

procedure TApplication.RunFrame;
var
  Dest: TRectangle;
  S: String;
  Key: TKeyboardKey;
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
      then RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0,
        GetScreenHeight * 1.333, GetScreenHeight)
      else RectangleCreate(0, (0.5 * GetScreenHeight) - (GetScreenWidth * 0.375
        ), GetScreenWidth, GetScreenWidth * 0.75);

    DrawTexturePro(
      Target.Texture,
      RectangleCreate(Overscan, Overscan, Target.texture.width - (2 * Overscan
        ), - Target.texture.height + (2 * Overscan)),
      Dest,
      Vector2Zero, 0, WHITE);
    EndShaderMode;

    if Assigned(Menu) then
    begin
      Menu.Render;
      DrawTexturePro(
        Menu.Texture,
        RectangleCreate(0, 0, Menu.Texture.width, -Menu.Texture.height),
        Dest,
        Vector2Zero, 0, ColorAlpha(WHITE, 0.975));
    end else
    if ShowKeyboard then
    begin
      Dest.height := KBTexture.height * Dest.width / KBTexture.width;
      DrawTexturePro(KBTexture,
        RectangleCreate(0, 0, KBTexture.width, KBTexture.height), Dest,
          Vector2Zero, 0, WHITE);
      DrawRectangleLinesEx(Dest, 1, RAYWHITE);
      Dest.y := Dest.height;
      DrawRectangleLinesEx(Dest, 1, RAYWHITE);
      Dest.height := Dest.height * 0.1;
      DrawRectangleRec(Dest, BLACK);
      DrawRectangleLinesEx(Dest, 1, RAYWHITE);

      DrawText(
        PChar('CAPS: [' + String.Join('], [', TKeyboard.GetKeyNames(Machine.Keyboard.CapsShiftKeys)) + ']'),
        Trunc(Dest.x + (Dest.width * 0.012)), Trunc(Dest.y + (Dest.height * 0.25)),
        Trunc(Dest.height * 0.5), YELLOW);

      DrawText(
        PChar('SYMB: [' + String.Join('] [', TKeyboard.GetKeyNames(Machine.Keyboard.SymbolShiftKeys)) + ']'),
        Trunc(Dest.x + (Dest.width * 0.512)), Trunc(Dest.y + (Dest.height * 0.25)),
        Trunc(Dest.height * 0.5), YELLOW);

      Dest.y := Dest.y + Dest.height;
      DrawRectangleRec(Dest, BLACK);
      DrawRectangleLinesEx(Dest, 1, RAYWHITE);

      S := '';
      if Assigned(Machine.Joystick) then
        for Key in Machine.Joystick.Keys do
          if Key <> KEY_NULL then
            S := S + $' [{TKeyboard.KeyName[Key]}]';

      DrawText(
        PChar('Joystick: ' + Machine.JoystickName + S),
        Trunc(Dest.x + (Dest.width * 0.012)), Trunc(Dest.y + (Dest.height * 0.25)),
        Trunc(Dest.height * 0.5), YELLOW);
    end;

    if not OSD.Text.IsEmpty then
      if GetTime < OSD.Lifetime then
      begin
        Dest.y := 10;
        DrawText(PAnsiChar(OSD.Text), Trunc(Dest.x) + 20, Trunc(Dest.y),
          GetScreenHeight div 12, ORANGE)
      end
      else
        OSD.Text := '';
  EndDrawing;
end;

function TApplication.BuildMenu: TMenu;
var
  SaveItem: TEditMenuItem;
begin
  Result := TMenu.Create(Self);

  Result.Root.AddItem('Resume', '',
    procedure(Sender: TMenuItem)
    begin
      Sender.Menu.Close;
    end);

  Result.Root.AddBrowser('Load', BrowsePath,
    procedure(Sender: TFileMenuItem)
    begin
      BrowseFiles(Sender);
    end);

  SaveItem := Result.Root.AddEdit('Save', 'Save snapshot as:',
    procedure(Sender: TEditMenuItem)
    var
      Error: String;
    begin
      if SaveSnapshot(Sender.Value, Error) then
        Sender.Menu.Close   { frees Sender - nothing may follow }
      else
        Sender.Warning := Error;
    end);

  SaveItem.OnApply := procedure(Sender: TMenuItem)
    begin
      Sender.Value := DefaultSaveName;
    end;

  SaveItem.OnChange := procedure(Sender: TEditMenuItem)
    begin
      DescribeSaveName(Sender);
    end;

  Result.Root.AddItem('TV-set', TVTypeNames[TVType],
    procedure(Sender: TMenuItem)
    begin
      TVType := (TVType + 1) mod 3;
      Sender.Value := TVTypeNames[TVType];
    end);

  Result.Root.AddItem('Joystick', Machine.JoystickName,
    procedure(Sender: TMenuItem)
    begin
      Machine.SwitchJoystick;
      Sender.Value := Machine.JoystickName;
    end);

  Result.Root.AddItem('Fullscreen', BoolToStr(Fullscreen, 'yes', 'no'),
    procedure(Sender: TMenuItem)
    begin
      Fullscreen := not Fullscreen;
      Sender.Value := BoolToStr(Fullscreen, 'yes', 'no');
    end);

  Result.Root.AddItem('Sound', BoolToStr(not Muted, 'yes', 'no'),
    procedure(Sender: TMenuItem)
    begin
      Muted := not Muted;
      Sender.Value := BoolToStr(not Muted, 'yes', 'no');
    end);

  Result.Root.AddItem('Reset', '',
    procedure(Sender: TMenuItem)
    begin
      Machine.Reset;
      Sender.Menu.Close;
    end);

  Result.Root.AddItem('Quit', '',
    procedure(Sender: TMenuItem)
    begin
      QuitRequested := True;
    end);
end;

function TApplication.GetPaused: Boolean;
begin
  Result := Assigned(Menu);
end;

procedure TApplication.SetMuted(AValue: Boolean);
begin
  if FMuted = AValue then Exit;
  FMuted := AValue;

  if Muted and IsAudioStreamPlaying(AudioStream) then
    StopAudioStream(AudioStream)
  else if IsAudioStreamValid(AudioStream) then
    PlayAudioStream(AudioStream);
end;

procedure TApplication.Run;
var
  I: Integer;
  Error: String;
begin
  Machine.Power := True;

  if GetEnvironmentVariable('SPEC_AUTOSAVE') <> '' then AutoLoadFrame := 100;

  if ParamCount > 0 then Snapshot := ParamStr(1);

  if not Snapshot.IsEmpty then
  begin
    { A bare name on the command line means a snapshot. }
    if TPath.GetExtension(Snapshot).IsEmpty then Snapshot := Snapshot + '.z80';
    if not LoadFile(Snapshot, Error) then
    begin
      SetOSD($'{TPath.GetFileName(Snapshot)}: {Error}', 5);
      Snapshot := '';
    end;
  end;

  FillByte(AccumBuf, SizeOf(AccumBuf), 0); { 0 = silence for signed 16-bit PCM }

  if not Muted then
  begin
    PlayAudioStream(AudioStream);

    for I := 1 to 3 do
      if IsAudioStreamProcessed(AudioStream) then
        UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);
  end;

  SetExitKey(KEY_NULL);

  while not (WindowShouldClose or QuitRequested) do RunFrame;

  StopAudioStream(AudioStream);
end;

procedure TApplication.HandleInput;
var
  Buffer: TImage;
begin
  if Assigned(Menu) then
  begin
    Menu.HandleInput;
    Exit;
  end
  else if IsKeyPressed(KEY_ESCAPE) then QuitRequested := True;

  if IsKeyPressed(KEY_F1) then
  begin
    Menu := BuildMenu;
    Menu.OnClose := procedure(ASender: TMenu; AQuit: Boolean)
      begin
        FreeAndNil(Menu);
      end;
  end;

  if IsKeyPressed(KEY_F11) then
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
    SetOSD($'TV type: {TVTypeNames[TVType]}');
  end;

  if IsKeyPressed(KEY_F6) then
  begin
    Machine.SwitchJoystick;
    SetOSD($'Joystick: {Machine.JoystickName}');
  end;

  if IsKeyPressed(KEY_F10) then Fullscreen := not Fullscreen;

  if IsKeyPressed(KEY_F8) and Machine.WavLoaded then
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
    { The border is not this procedure's business - PaintBorderUntil lays it
      down on the ULA's own clock. }
    Y := ALine - ScreenTop;
    if not InRange(Y, 0, 191) then Exit;

    { Screen layout: third, then pixel Y within the character row, then
      character row within the third. }
    Offset := 16384;
    Inc(Offset, (Y div 64) * 2048);
    Inc(Offset, ((Y mod 64) div 8) * 32);
    Inc(Offset, (Y mod 8) * 256);

    AttrOffset := 22528 + ((Y div 8) * 32);
    PixelIndex := ((Y + ScreenTop) * ImageWidth) + ScreenLeft;

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
  { Row 0's left border is drawn before the frame's first display byte. }
  BorderT := -BorderPhaseT;

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

  { Nothing changed the colour after the last OUT - carry it to the bottom. }
  PaintBorderUntil(TStatesPerFrame);
end;

procedure TApplication.RenderAudioFrame;
begin
  if AutoLoadFrame >= 0 then
    if GetEnvironmentVariable('SPEC_AUTOSAVE') <> '' then
      RunAutoSaveScript(Int64(Machine.Frames) - AutoLoadFrame)
    else
      RunAutoLoadScript(Int64(Machine.Frames) - AutoLoadFrame);

  AdvanceAudio(TStatesPerFrame);
  PrevTiming := 0;
  PrevT := 0;
  BucketStartT := 0;
  BucketHigh := 0;
  BucketTapeHigh := 0;

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
  Config.WriteBool('Audio', 'Muted', Muted);
  Config.WriteBool('Tape', 'Sound', TapeSound);
  Config.WriteBool('Tape', 'Save', Machine.SaveToWav);

  Config.WriteInteger('Joystick', 'Index', Machine.JoystickIndex);
end;

{ Paints every border pixel the beam has swept between BorderT and AT in the
  colour currently on the port, then parks the cursor at AT. Frame T-states map
  onto the raster linearly at two pixel slots per T-state, so the run is walked
  a row at a time, clipping each row to the visible image and stepping around
  the display window. }
procedure TApplication.PaintBorderUntil(AT: Integer);
var
  Color: DWord;
  Slot, SlotEnd, RowBase, Y, X, XEnd: Integer;
begin
  if AT > TStatesPerFrame then AT := TStatesPerFrame;
  if AT <= BorderT then Exit;

  Color := PDWord(@Palette[Machine.BorderColorIndex])^;
  Slot := (BorderT + BorderPhaseT) * 2;
  SlotEnd := (AT + BorderPhaseT) * 2;
  BorderT := AT;

  while Slot < SlotEnd do
  begin
    Y := Slot div SlotsPerScanline;
    RowBase := Y * SlotsPerScanline;
    X := Slot - RowBase;
    XEnd := Min(SlotEnd - RowBase, ImageWidth);
    Slot := RowBase + SlotsPerScanline;   { the blanking tail is skipped with it }

    if not InRange(Y, 0, ImageHeight - 1) then Continue;
    if X >= XEnd then Continue;

    RowBase := Y * ImageWidth;
    if not InRange(Y, ScreenTop, ScreenBottom - 1) then
    begin
      { Above or below the screen: the row is border edge to edge. }
      FillDWord(Pixels^[RowBase + X], XEnd - X, Color);
      Continue;
    end;

    if X < ScreenLeft then
      FillDWord(Pixels^[RowBase + X], Min(XEnd, ScreenLeft) - X, Color);

    if XEnd > ScreenRight then
    begin
      if X < ScreenRight then X := ScreenRight;
      FillDWord(Pixels^[RowBase + X], XEnd - X, Color);
    end;
  end;
end;

procedure TApplication.OnBorderChange(AIndex: TZXColorIndex; ACycles: Integer);
begin
  { Fired before the machine adopts AIndex, so the colour still on the port is
    the one the beam has been laying down up to this instant. }
  PaintBorderUntil(ACycles);
end;

end.

