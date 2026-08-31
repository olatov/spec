unit main;

{$mode unleashed}

{$ifdef darwin}
  {
    raylib paces frames by waiting out whatever is left of the target period
    after the frame's own work - rcore.c does WaitTime(target - update - draw)
    - which is measured against that one frame and never against a running
    schedule, so however far the wait overshoots is kept rather than made up.
    On macOS that wait ends in usleep() with a 5% busy-wait reserve, around
    0.8 ms of a 16.5 ms wait, and macOS overshoots that often enough to matter:
    frames come out at 20.13 ms instead of 20.00.

    A 0.7% shortfall is invisible as video and fatal as audio. The emulator
    ends up generating about 43,800 samples a second for a device consuming
    44,100, so the stream's two 100 ms buffers run dry some twelve seconds in,
    and from then on every chunk arrives into a device that has already played
    silence - a click, ten times a second, for the rest of the session. Linux
    takes WaitTime's nanosleep branch instead, whose overshoot stays inside the
    reserve, which is why none of this shows up there.

    Run's loop below keeps an absolute schedule of its own instead, so a frame
    that overshoots is made up by the next one rather than by every one after
    it, and NanoSleep replaces the frame limiter.
  }
  {$define USE_DELAY}
{$endif}

interface

uses
  {$ifdef mswindows} Windows, {$endif}
  Classes, SysUtils, Math, CTypes, IniFiles, System.IOUtils,
  Raylib, RayMath,
  {$ifdef USE_DELAY} Utils, {$endif}
  Z80, Spectrum, OSDMenu, Keyboards, Joysticks, Catalogs;

type
  TSimpleTimer = record
    Enabled: Boolean;
    Countdown: Double;
  end;

  TApplication = class(TComponent)
  private
    FFullscreen: Boolean;
    Config: TIniFile;
    FMuted: Boolean;
    FTapeAutoLoad: Boolean;
    FCatalogPage: TCatalogMenuItem;   { valid only while Menu is - see BuildMenu }
    FQuitTimer: TSimpleTimer;
    FAutoLoad: record
      Active: Boolean;
      Frame: Integer;
    end;
    { GetTime deadline for a one-shot re-prime of the audio stream after the
      device has warmed up, or 0 when none is pending. See Run. }
    FAudioWarmup: Double;
    procedure AdvanceAudio(NewT: Integer);
    function BuildMenu: TMenu;
    procedure AddControlsPage(AParent: TMenuItem);
    procedure RefreshControls(APage: TMenuItem);
    function LoadFont: TFont;
    function LoadKeyboardTexture: TTexture2D;
    function LoadStream(const AFilename: String; AStream: TStream; out
      AError: String; AForceAutoLoad: Boolean = False): Boolean;
    procedure OpenMenu(ACatalog: Boolean = False);
    function GetPaused: Boolean;
    procedure SetMuted(AValue: Boolean);
    procedure SetTapeAutoLoad(AValue: Boolean);
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
    procedure PrimeAudio;
    function AutoLoadAction(Frame: Int64): Boolean;
  public
    Machine: TZXSpectrum48;
    AudioStream: TAudioStream;
    AudioVolume: Single;
    Target: TRenderTexture2D;
    Font: TFont;
    KeyboardTexture: TTexture2D;
    ShowKeyboard: Boolean;
    ShowMenu: Boolean;
    Image: TImage;
    Video: TTexture2D;
    Menu: TMenu;
    { Test-automation support (opt-in via SPEC_AUTOLOAD / SPEC_AUTOSAVE env
      vars): scripts the LOAD or SAVE keystrokes via raylib automation events,
      so tape loading and saving can be verified without a real keyboard or
      window focus. }
    AutoLoadFrame: Int64;
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
    BorderT: Integer;
    CurrentFile: String;
    Aspect: Boolean;
    Curvature: Single;
    Turbo: Boolean;
    property TapeAutoLoad: Boolean read FTapeAutoLoad write SetTapeAutoLoad;
    { Frame T-state the border has been painted up to. The ULA lays the border
      down in real time, so it is filled in lazily: whenever the colour is
      about to change (and once at the end of the frame) everything the beam
      has covered since the last catch-up is painted in the outgoing colour. }
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
  TVTypeNames: array[0..2] of String = ('Colour CRT', 'B/W CRT', 'Modern');

  { What the file browser offers and LoadFile knows how to open. Anything else
    is left out of the list rather than failing once it is picked. }
  LoadableExtensions: array[0..2] of String = ('.z80', '.tap', '.wav');

var
  TapeFile: String = '';
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

implementation

{$R main.rc}

procedure SetOSD(AText: String; ADuration: Double = 2); forward;

{$ifdef DEBUG_AUDIO}
{ ---------------------------------------------------------------------------
  Audio pacing instrumentation. Off unless SPEC_AUDIO_STATS=1 is set in the
  environment, at which point a summary lands on stdout once a second.

  The sample producer (RenderAudioFrame, paced by the 50 fps loop off the
  system clock) and the audio device (paced by its own clock) run open loop
  with only two chunks of buffer between them and no feedback. Either side
  slipping is audible as a click: too fast and RenderAudioFrame discards a
  whole chunk because the stream is still busy, too slow and the device runs
  out and raylib pads with silence. These counters say which is happening,
  and whether the cause is a steady drift or a one-off scheduling spike. }

type
  TStatsSegment = record
    Sum, Peak: Double;
  end;

const
  StatsInterval = 1.0;   { seconds between summary lines }

  { Rates a device plausibly runs at. The mixed-output probe below counts
    frames in the device's own rate, not ours, so the measured consume rate is
    snapped to one of these to express drift as a fraction of real time. }
  StatsRates: array[0..3] of Integer = (44100, 48000, 88200, 96000);

var
  Stats: record
    Enabled: Boolean;
    Start, NextReport: Double;

    { main thread }
    LastFrame, LastPush: Double;
    ChunksPushed, ChunksDropped, ChunksStarved: Int64;
    GapMin, GapPeak, GapSum, UpdatePeak: Double;
    GapCount, Frames, IdleFrames: Integer;
    Period, Emu, Blit, Present: TStatsSegment;

    { audio thread. Single writer, read from the main thread without
      synchronisation: an aligned 64-bit counter cannot tear on either target,
      and losing the odd extreme to a torn reset costs nothing here. }
    FramesConsumed: Int64;
    BlockMin, BlockPeak: LongWord;
    LastCallback, CallbackGapPeak: Double;

    { Interval baselines. Rates are computed over the last interval only, so
      they are not skewed by the chunks primed into the stream at startup, and
      each rate is measured between its own events rather than over the report
      window - counting whole 100 ms chunks against a ~1 s window quantises the
      producer rate to 10%, which swamps the drift being looked for. }
    MarkTime, MarkConsumedAt: Double;
    MarkPushed, MarkDropped, MarkStarved, MarkConsumed: Int64;
  end;

{ Runs on the audio device thread, on every device callback, whether or not
  anything is playing. Stays allocation- and lock-free: it only reads the
  clock and bumps counters.

  Stack checking is off for this one routine (see $S- below). miniaudio's device
  thread is not one FPC started, so the RTL's per-thread StackBottom for it is
  never initialised and still holds the main thread's bounds. The device
  thread's stack sits well outside those, so the -Ct prologue check here
  mistakes the first callback for a stack overflow and raises RTE 202. The
  body touches no threadvars, heap or exceptions, so skipping the check is
  safe; the rest of the unit keeps it. }
{$push}{$S-}
procedure AudioStatsProbe(ABuffer: Pointer; AFrames: LongWord); cdecl;
var
  Now: Double;
begin
  Now := GetTime;
  if (Stats.LastCallback > 0) and (Now - Stats.LastCallback > Stats.CallbackGapPeak) then
    Stats.CallbackGapPeak := Now - Stats.LastCallback;
  Stats.LastCallback := Now;

  if AFrames < Stats.BlockMin then Stats.BlockMin := AFrames;
  if AFrames > Stats.BlockPeak then Stats.BlockPeak := AFrames;

  { Written last, so a main thread that has already read LastCallback and then
    sees this unchanged knows the pair it holds is consistent. }
  Inc(Stats.FramesConsumed, AFrames);
end;
{$pop}

{ Reads the (frame count, timestamp) pair the probe maintains without stopping
  it, retrying while a callback lands in the middle. The callbacks are 10 ms
  apart, so this effectively never spins. }
procedure StatsReadConsumed(out AFrames: Int64; out AAt: Double);
var
  Before: Int64;
  I: Integer;
begin
  for I := 1 to 8 do
  begin
    Before := Stats.FramesConsumed;
    AAt := Stats.LastCallback;
    AFrames := Stats.FramesConsumed;
    if AFrames = Before then Exit;
  end;
end;

procedure StatsAdd(var ASegment: TStatsSegment; AMilliseconds: Double); inline;
begin
  ASegment.Sum := ASegment.Sum + AMilliseconds;
  if AMilliseconds > ASegment.Peak then ASegment.Peak := AMilliseconds;
end;

function StatsMean(const ASegment: TStatsSegment): Double; inline;
begin
  Result := ASegment.Sum / Max(Stats.Frames, 1);
end;

function StatsNearestRate(AMeasured: Double): Integer;
var
  I: Integer;
begin
  Result := StatsRates[0];
  for I := 1 to High(StatsRates) do
    if Abs(AMeasured - StatsRates[I]) < Abs(AMeasured - Result) then
      Result := StatsRates[I];
end;

procedure StatsInit;
begin
  Stats.Enabled := GetEnvironmentVariable('SPEC_AUDIO_STATS') = '1';
  if not Stats.Enabled then Exit;

  Stats.Start := GetTime;
  Stats.MarkTime := Stats.Start;
  Stats.NextReport := Stats.Start + StatsInterval;
  Stats.GapMin := Infinity;
  Stats.BlockMin := High(LongWord);

  AttachAudioMixedProcessor(@AudioStatsProbe);

  Writeln($'[audio] {AudioFrequency} Hz, chunk {AudioChunkFrames} frames ' +
    $'({AudioChunkFrames * 1000 / AudioFrequency:%.1f} ms), target {FPS} fps ' +
    $'({SamplesPerFrame} frames/video frame)');
  Flush(Output);
end;

procedure StatsShutdown;
begin
  if not Stats.Enabled then Exit;
  Stats.Enabled := False;
  DetachAudioMixedProcessor(@AudioStatsProbe);
end;

{ Called once per completed chunk, whether or not the stream accepted it. }
procedure StatsChunk(AAccepted, AStarved: Boolean; AUpdateMilliseconds: Double);
var
  Now, Gap: Double;
begin
  if not Stats.Enabled then Exit;

  Now := GetTime;
  if Stats.LastPush > 0 then
  begin
    Gap := (Now - Stats.LastPush) * 1000;
    if Gap < Stats.GapMin then Stats.GapMin := Gap;
    if Gap > Stats.GapPeak then Stats.GapPeak := Gap;
    Stats.GapSum := Stats.GapSum + Gap;
    Inc(Stats.GapCount);
  end;
  Stats.LastPush := Now;

  if AUpdateMilliseconds > Stats.UpdatePeak then Stats.UpdatePeak := AUpdateMilliseconds;
  if AAccepted then Inc(Stats.ChunksPushed) else Inc(Stats.ChunksDropped);
  if AStarved then Inc(Stats.ChunksStarved);
end;

procedure StatsReport;
var
  Now, Span, MeanGap, ConsumedAt, ConsumeSpan: Double;
  GenerateHz, ConsumeHz, GenerateX, ConsumeX: Double;
  Device: Integer;
  Pushed, Dropped, Starved, Consumed: Int64;
begin
  Now := GetTime;
  Span := Now - Stats.MarkTime;
  if (Span <= 0) or (Stats.Frames = 0) then Exit;

  Pushed := Stats.ChunksPushed - Stats.MarkPushed;
  Dropped := Stats.ChunksDropped - Stats.MarkDropped;
  Starved := Stats.ChunksStarved - Stats.MarkStarved;
  StatsReadConsumed(Consumed, ConsumedAt);

  { Generation is what the emulator produced, accepted or not - that is the
    producer's clock, and every chunk is exactly AudioChunkFrames, so the mean
    interval between chunks gives the rate directly. Delivery is Pushed alone. }
  MeanGap := Stats.GapSum / Max(Stats.GapCount, 1);
  GenerateHz := if Stats.GapCount > 0 then AudioChunkFrames * 1000 / MeanGap else 0;

  { MarkConsumedAt is 0 until the probe has been through a full interval, and
    the first report would otherwise measure from the epoch. }
  ConsumeSpan := ConsumedAt - Stats.MarkConsumedAt;
  ConsumeHz := if (Stats.MarkConsumedAt > 0) and (ConsumeSpan > 0)
    then (Consumed - Stats.MarkConsumed) / ConsumeSpan
    else 0;

  Device := StatsNearestRate(ConsumeHz);
  GenerateX := GenerateHz / AudioFrequency;
  ConsumeX := ConsumeHz / Device;

  Writeln($'[audio {Now - Stats.Start:%7.1f}s] chunks {Pushed} pushed, ' +
    $'{Dropped} dropped ({Stats.ChunksDropped} total), ' +
    $'{Starved} starved ({Stats.ChunksStarved} total)   ' +
    $'gap ms {Stats.GapMin:%.2f}/{MeanGap:%.2f}/{Stats.GapPeak:%.2f}   ' +
    $'UpdateAudioStream peak {Stats.UpdatePeak:%.2f} ms');

  Writeln($'                  rate generate {GenerateHz:%9.1f} Hz ({GenerateX:%.6f}x)   ' +
    $'consume {ConsumeHz:%9.1f} Hz ({ConsumeX:%.6f}x of {Device})   ' +
    $'drift {(GenerateX - ConsumeX) * 1000000:%.0f} ppm');

  Writeln($'                  device block {Stats.BlockMin}..{Stats.BlockPeak} frames, ' +
    $'callback gap peak {Stats.CallbackGapPeak * 1000:%.2f} ms');

  Writeln($'                  frame ms period {StatsMean(Stats.Period):%.2f}/{Stats.Period.Peak:%.2f}   ' +
    $'emu {StatsMean(Stats.Emu):%.2f}/{Stats.Emu.Peak:%.2f}   ' +
    $'blit {StatsMean(Stats.Blit):%.2f}/{Stats.Blit.Peak:%.2f}   ' +
    $'present {StatsMean(Stats.Present):%.2f}/{Stats.Present.Peak:%.2f}   ' +
    $'({Stats.Frames} frames, {Stats.IdleFrames} idle)');

  if Stats.IdleFrames > 0 then
    Writeln('                  (idle frames were paused or muted - no audio was ' +
      'generated in them, so the rates above understate generation)');

  Flush(Output);

  Stats.MarkTime := Now;
  Stats.MarkPushed := Stats.ChunksPushed;
  Stats.MarkDropped := Stats.ChunksDropped;
  Stats.MarkStarved := Stats.ChunksStarved;
  Stats.MarkConsumed := Consumed;
  Stats.MarkConsumedAt := ConsumedAt;
  Stats.NextReport := Now + StatsInterval;

  Stats.GapMin := Infinity;
  Stats.GapPeak := 0;
  Stats.GapSum := 0;
  Stats.GapCount := 0;
  Stats.UpdatePeak := 0;
  Stats.Frames := 0;
  Stats.IdleFrames := 0;
  Stats.Period := Default(TStatsSegment);
  Stats.Emu := Default(TStatsSegment);
  Stats.Blit := Default(TStatsSegment);
  Stats.Present := Default(TStatsSegment);
  Stats.BlockMin := High(LongWord);
  Stats.BlockPeak := 0;
  Stats.CallbackGapPeak := 0;
end;

{ AEmuDone/ABlitDone/AFrameDone are GetTime readings taken at the end of each
  stage of RunFrame. "present" covers EndDrawing, so it also carries raylib's
  own wait whenever SetTargetFPS is doing the pacing - a large figure there is
  normal in that case, and only the residue of the swap when the frame limiter
  lives in the caller's loop instead. The number that must stay at 20 ms either
  way is "period", the wall time between the starts of consecutive frames. }
procedure StatsFrame(AStart, AEmuDone, ABlitDone, AFrameDone: Double; AIdle: Boolean);
begin
  if not Stats.Enabled then Exit;

  Inc(Stats.Frames);
  if AIdle then Inc(Stats.IdleFrames);

  if Stats.LastFrame > 0 then StatsAdd(Stats.Period, (AStart - Stats.LastFrame) * 1000);
  Stats.LastFrame := AStart;

  StatsAdd(Stats.Emu, (AEmuDone - AStart) * 1000);
  StatsAdd(Stats.Blit, (ABlitDone - AEmuDone) * 1000);
  StatsAdd(Stats.Present, (AFrameDone - ABlitDone) * 1000);

  if AFrameDone >= Stats.NextReport then StatsReport;
end;
{$endif DEBUG_AUDIO}

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
  Names := autofree TStringList.Create;
  try
    for Filename in TDirectory.GetFiles(SaveDir, '*.z80') do
      Names.Add(TPath.GetFileName(Filename));
  except
    { unreadable folder - the dialog simply lists nothing }
  end;

  Names.Sort;
  Result := Names.ToStringArray;
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

{ The name the Save field opens on: the loaded TapeFile's or tape's own name,
  numbered up so a second save of the same game doesn't land on the first. }
function TApplication.DefaultSaveName: String;
var
  Base, Candidate: String;
  Suffix: Integer = 0;
begin
  Base := TPath.GetFileNameWithoutExtension(TapeFile);
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
  Names := autofree TStringList.Create;
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
        SetOSD($'Loading {TPath.GetFileName(Sender.Data)}');
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

{ Opens whatever kind of file this is. A TapeFile simply becomes the machine's
  state; a tape is inserted and the machine rewound to a bare BASIC prompt, so
  the scripted LOAD "" is typed into the ROM's editor and not into whatever
  happened to be running. }
function TApplication.LoadFile(const AFilename: String; out AError: String): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  if not TFile.Exists(AFilename) then
  begin
    AError := 'File not found';
    Exit;
  end;

  Stream := autofree TFile.OpenRead(AFilename);
  Result := LoadStream(AFilename, Stream, AError);
end;

function TApplication.LoadStream(const AFilename: String; AStream: TStream; out AError: String;
  AForceAutoLoad: Boolean): Boolean;
var
  Extension: String;
  Tape: Boolean;
begin
  Result := False;

  Extension := TPath.GetExtension(AFilename).ToLower;
  Tape := (Extension = '.tap') or (Extension = '.wav');

  try
    if Extension = '.tap' then
      Result := Machine.LoadTAP(AStream)
    else if Extension = '.wav' then
      { Real-time load: the ROM/turbo loader polls the EAR line; playback
        auto-starts (and auto-pauses between blocks) once LD-BYTES runs. }
      Result := Machine.LoadWAV(AStream)
    else
    begin
      Machine.LoadZ80(AStream);
      CurrentFile := AFilename;
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

  TapeFile := AFilename;   { the Save field takes its default name from here }
  CurrentFile := AFilename;

  if Tape and (TapeAutoLoad or AForceAutoLoad) then
  begin
    Machine.Reset;
    FAutoLoad.Active := True;
    FAutoLoad.Frame := 0;
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
function TApplication.AutoLoadAction(Frame: Int64): Boolean;
begin
  if Frame > 142 then Exit(False);
  case Frame of
    100: AutoKeyEvent(INPUT_KEY_DOWN, KEY_J);
    103: AutoKeyEvent(INPUT_KEY_UP, KEY_J);
    105: AutoKeyEvent(INPUT_KEY_DOWN, Machine.Keyboard.SymbolShiftKey);
    107: AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    110: AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    112: AutoKeyEvent(INPUT_KEY_UP, Machine.Keyboard.SymbolShiftKey);
    122: AutoKeyEvent(INPUT_KEY_DOWN, Machine.Keyboard.SymbolShiftKey);
    124: AutoKeyEvent(INPUT_KEY_DOWN, KEY_P);
    127: AutoKeyEvent(INPUT_KEY_UP, KEY_P);
    129: AutoKeyEvent(INPUT_KEY_UP, Machine.Keyboard.SymbolShiftKey);
    139: AutoKeyEvent(INPUT_KEY_DOWN, KEY_ENTER);
    142: AutoKeyEvent(INPUT_KEY_UP, KEY_ENTER);
  end;
  Result := True;
end;

procedure SetOSD(AText: String; ADuration: Double = 2);
begin
  OSD.Text := AText;
  OSD.Lifetime := GetTime + ADuration;
end;

function LoadLib80: Boolean;
var
  SearchPaths: array of String = ('.', './lib');
  LibZ80Path: String;
  SearchPath: String;

  function TryLoad(AFileName: String): Boolean;
  begin
    try
      TraceLog(LOG_INFO, PChar($'Trying {AFileName}'));
      Result := LoadLibrary(AFileName);
      if Result then
        TraceLog(LOG_INFO, PChar($'Loaded {AFileName}'))
      else
        TraceLog(LOG_WARNING, PChar($'{AFileName} could not be loaded'));
    except
      on E: Exception do
        TraceLog(LOG_ERROR, PChar($'Error loading {AFileName}: {E.Message}'));
    end;
  end;

begin
  LibZ80Path := GetEnvironmentVariable('LIBZ80_PATH');
  if not LibZ80Path.IsEmpty then
  begin
    Result := TryLoad(LibZ80Path);
    Exit;
  end;

  for SearchPath in SearchPaths do
  begin
    Result := TryLoad(SetDirSeparators(TPath.Combine(SearchPath, DefaultZ80LibPath)));
    if Result then Exit;
  end;
end;

constructor TApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  SetTraceLogLevel(LOG_ERROR);

  if not LoadLib80 then
    raise Exception.Create('Fatal: unable to load Z80 library');

  Machine := TZXSpectrum48.Create;
  Config := TIniFile.Create(GetAppConfigFile(False));
end;

destructor TApplication.Destroy;
var
  I: Integer;
begin
  inherited Destroy;

  if Assigned(Config) then SaveConfig;
  FreeAndNil(Config);

  FreeAndNil(Machine);

  {$ifdef DEBUG_AUDIO}
    StatsShutdown;
  {$endif}
  if IsAudioStreamValid(AudioStream) then UnloadAudioStream(AudioStream);
  if IsAudioDeviceReady then CloseAudioDevice;

  if IsFontValid(Font) then UnloadFont(Font);

  for I := 0 to High(Shaders) do
    if IsShaderValid(Shaders[I]) then UnloadShader(Shaders[I]);

  if IsRenderTextureValid(Target) then UnloadRenderTexture(Target);
  if IsTextureValid(Video) then UnloadTexture(Video);
  if IsImageValid(Image) then UnloadImage(Image);

  if IsTextureValid(KeyboardTexture) then UnloadTexture(KeyboardTexture);

  if IsWindowReady then CloseWindow;
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
  Control: TJoystickControl;
  LinesCount: Single = 256;
begin
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

  {$ifndef USE_DELAY}
    SetTargetFPS(FPS)
  {$endif};
  SetWindowState(FLAG_WINDOW_RESIZABLE);
  ClearWindowState(FLAG_VSYNC_HINT);

  Fullscreen := Config.ReadBool('Window', 'Fullscreen', True);

  Font := Self.LoadFont;

  TVType := Config.ReadInteger('Display', 'TVType', TVTypeColor) mod Length(Shaders);
  Overscan := Config.ReadInteger('Display', 'Overscan', 16);
  Aspect := Config.ReadBool('Display', 'Aspect', True);
  Curvature := Config.ReadFloat('Display', 'Curvature', 7.0);
  TapeSound := Config.ReadBool('Tape', 'Sound', True);
  Machine.SaveToWav := Config.ReadBool('Tape', 'Save', True);
  Machine.OnTapeSaved := @TapeSaved;

  TapeAutoLoad := Config.ReadBool('Tape', 'AutoLoad', True)
    or not GetEnvironmentVariable('SPEC_AUTOLOAD').IsEmpty;

  SavePath := Config.ReadString('Files', 'SavePath', '');
  BrowsePath := SaveDir;

  Machine.JoystickIndex := Config.ReadInteger('Joystick', 'Index', 1);
  if Machine.JoystickIndex >= Machine.Joysticks.Count then
    Machine.JoystickIndex := 0;

  for I := 0 to 7 do
    if IsGamepadAvailable(I) then
    begin
      TJoystick.GamepadIndex := I;
      Break;
    end;

  { Each binding falls back to the built-in one, written out the same way the
    config would have it, so an unreadable or absent setting costs that one
    control rather than the lot. }
  for Control := Low(TJoystickControl) to High(TJoystickControl) do
    TJoystick.Bindings[Control] := TKeyboard.KeyFromId(
      Config.ReadString('Joystick', JoystickControlNames[Control],
        TKeyboard.KeyId[TJoystick.Bindings[Control]]));

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture,
     if Config.ReadBool('Video', 'Filter', True)
      then TEXTURE_FILTER_BILINEAR
      else TEXTURE_FILTER_POINT);

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

  KeyboardTexture := LoadKeyboardTexture;

  Image := GenImageColor(ImageWidth, ImageHeight, BLACK);
  Pixels := Image.data;
  Video := LoadTextureFromImage(Image);

  InitAudioDevice;

  SetAudioStreamBufferSizeDefault(AudioChunkFrames);
  AudioStream := LoadAudioStream(AudioFrequency, 16, 1);
  SetVolume(Config.ReadFloat('Audio', 'Volume', 0.4));
  Muted := Config.ReadBool('Audio', 'Muted', False);

  {$ifdef DEBUG_AUDIO}
    StatsInit;
  {$endif}
end;

function TApplication.LoadFont: TFont;
var
  Stream: TResourceStream;
begin
  Stream := autofree TResourceStream.Create(HINSTANCE, 'MAIN_FONT', RT_RCDATA);
  Result := LoadFontFromMemory('.otf', Stream.Memory, Stream.Size, 24, Nil, 0);
end;

function TApplication.LoadKeyboardTexture: TTexture2D;
var
  Buffer: TImage;
  Stream: TResourceStream;
begin
  Stream := autofree TResourceStream.Create(HINSTANCE, 'IMAGE_KEYBOARD', RT_RCDATA);
  Buffer := LoadImageFromMemory('.png', Stream.Memory, Stream.Size);
  Result := LoadTextureFromImage(Buffer);
  SetTextureFilter(Result, TEXTURE_FILTER_BILINEAR);
  UnloadImage(Buffer);
end;

procedure TApplication.SetVolume(AVolume: Single; K: Single = 4);
begin
  AudioVolume := EnsureRange(AVolume, 0, 1.0);
  SetAudioStreamVolume(AudioStream, (Exp(K * AudioVolume) - 1) / (Exp(K) - 1));
end;

procedure TApplication.RunFrame;
var
  Dest, Highlight: TRectangle;
  Files: TFilePathList;
  Filename, ErrorMessage: String;
  Scale, PixelAspect: Single;
  {$ifdef DEBUG_AUDIO}
    Started, EmuDone, BlitDone: Double;
    Idle: Boolean;
  {$endif}
begin
  if IsFileDropped then
  begin
    Files := LoadDroppedFiles;
    try
      if Files.count > 0 then
      begin
        Filename := Files.paths[0];
        if not LoadFile(Filename, ErrorMessage) then
          SetOSD($'{Filename}: {ErrorMessage}', 5);
      end;
    finally
      UnloadDroppedFiles(Files);
    end;
  end;

  if FQuitTimer.Enabled then
  begin
    FQuitTimer.Countdown := FQuitTimer.Countdown - GetFrameTime;
    FQuitTimer.Enabled := FQuitTimer.Countdown > 0;
  end;

  {$ifdef DEBUG_AUDIO}
    Started := GetTime;
    Idle := Paused or Muted;
  {$endif}

  HandleInput;

  if not Paused then
  begin
    RenderVideoFrame;
    RenderAudioFrame;

    if FAutoLoad.Active then
    begin
      FAutoLoad.Frame := FAutoLoad.Frame + 1;
      FAutoLoad.Active := AutoLoadAction(FAutoLoad.Frame);
    end;
  end;

  {$ifdef DEBUG_AUDIO}
    EmuDone := GetTime;
  {$endif}

  UpdateTexture(Video, Image.data);

  BeginTextureMode(Target);
    DrawTexturePRO(Video,
      RectangleCreate(0, 0, Video.width, Video.height),
      RectangleCreate(0, 0, Target.texture.width, Target.texture.height),
      Vector2Zero, 0, WHITE);
  EndTextureMode;

  {$ifdef DEBUG_AUDIO}
    BlitDone := GetTime;
  {$endif}

  BeginDrawing;
    ClearBackground(BLACK);
    BeginShaderMode(Shaders[TVType]);

    if Aspect then
      Dest := if (GetScreenWidth / GetScreenHeight) >= 1.333
        then RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0,
          GetScreenHeight * 1.333, GetScreenHeight)
        else RectangleCreate(0, (0.5 * GetScreenHeight) - (GetScreenWidth * 0.375
          ), GetScreenWidth, GetScreenWidth * 0.75)
    else
      RectangleSet(@Dest, 0, 0, GetScreenWidth, GetScreenHeight);

    { The render target is 352x288, not 4:3 - the 4:3 comes from Dest. Cropping
      the overscan border in proportion to the target's own aspect keeps the
      crop rect's aspect equal to the full frame's, so the trim is a uniform
      zoom rather than a horizontal stretch that grows with the setting. }
    PixelAspect := Target.texture.width / Target.texture.height;

    DrawTexturePro(
      Target.Texture,
      RectangleCreate(Overscan * PixelAspect, Overscan,
        Target.texture.width - (2 * PixelAspect * Overscan),
        - Target.texture.height + (2 * Overscan)),
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
        Vector2Zero, 0, WHITE);
    end
    else if ShowKeyboard then
    begin
      Dest.height := KeyboardTexture.height * Dest.width / KeyboardTexture.width;
      DrawTexturePro(KeyboardTexture,
        RectangleCreate(0, 0, KeyboardTexture.width, KeyboardTexture.height), Dest,
          Vector2Zero, 0, WHITE);
      DrawRectangleLinesEx(Dest, 1, RAYWHITE);

      Scale := Dest.width / KeyboardTexture.width;
      for Highlight in Machine.Keyboard.GetHighlights do
      begin
        DrawRectangleRec(
          RectangleCreate(
            Dest.x + (Highlight.x * Scale),
            Dest.y + (Highlight.y * Scale),
            Highlight.width * Scale,
            Highlight.height * Scale),
          ColorAlpha(WHITE, 0.4));
      end;
    end;

    if not OSD.Text.IsEmpty then
      if GetTime < OSD.Lifetime then
      begin
        DrawRectangle(Trunc(Dest.x), Trunc(Dest.y),
          Trunc(Dest.width), Trunc(Dest.height * 0.1),
          ColorAlpha(DARKMAGENTA, 0.67));
        DrawTextEx(Font,
        PAnsiChar(OSD.Text),
          [Dest.x + 20, Dest.y + 8],
          Trunc(Dest.height * 0.08), 0, ORANGE)
      end
      else
        OSD.Text := '';
  EndDrawing;

  {$ifdef DEBUG_AUDIO}
    StatsFrame(Started, EmuDone, BlitDone, GetTime, Idle);
  {$endif}
end;

function TApplication.BuildMenu: TMenu;
var
  SaveItem: TEditMenuItem;
begin
  Result := TMenu.Create(Self, Font);

  Result.Root.AddItem('Resume', '',
    procedure(Sender: TMenuItem)
    begin
      Sender.Menu.Close;
    end);

    { The Catalog page is built from the list, and every entry on it carries its
      own path - so one handler serves all of them, and it is the browser's Open
      handler with the folders left out. }
    FCatalogPage := Nil;
    if not Catalog.IsEmpty then
      FCatalogPage := AddCatalogPage(Result.Root,
        procedure(Sender: TMenuItem)
        var
          Error: String;
          Stream: TStream;
        begin
          {$ifdef EMBED_CATALOG}
            Stream := autofree TResourceStream.Create(
              HINSTANCE, 'GAME_' + TPath.GetFileName(Sender.Data), RT_RCDATA);
          {$else}
            Stream := autofree TFile.OpenRead(Sender.Data);
          {$endif}
          { Picking a game from the catalog means "play this", so its tape is
            auto-loaded whether or not the setting is on. }
          if LoadStream(Sender.Data, Stream, Error, True) then
          begin
            SetOSD($'Loaded {Sender.Text}');
            Sender.Menu.Close;   { frees Sender - nothing may follow }
          end
          else
            Sender.Parent.Warning := Error;
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

  Result.Root.AddItem('Joystick', Machine.JoystickName,
    procedure(Sender: TMenuItem)
    begin
      Machine.SwitchJoystick;
      Sender.Value := Machine.JoystickName;
    end);

  AddControlsPage(Result.Root);

  Result.Root.AddItem('TV-set', TVTypeNames[TVType],
    procedure(Sender: TMenuItem)
    begin
      TVType := (TVType + 1) mod 3;
      Sender.Value := TVTypeNames[TVType];
    end);

  Result.Root.AddItem('Fullscreen', BoolToStr(Fullscreen, 'yes', 'no'),
    procedure(Sender: TMenuItem)
    begin
      Fullscreen := not Fullscreen;
      Sender.Value := BoolToStr(Fullscreen, 'yes', 'no');
    end);

  Result.Root.AddItem('Aspect', BoolToStr(Aspect, '4:3', 'no'),
  procedure(Sender: TMenuItem)
  begin
    Aspect := not Aspect;
    Sender.Value := BoolToStr(Aspect, '4:3', 'no');
  end);

  Result.Root.AddItem('Sound', BoolToStr(not Muted, 'yes', '-'),
    procedure(Sender: TMenuItem)
    begin
      Muted := not Muted;
      Sender.Value := BoolToStr(not Muted, 'yes', 'no');
    end);

  Result.Root.AddItem('Auto-load tapes', BoolToStr(TapeAutoLoad, 'yes', 'no'),
    procedure(Sender: TMenuItem)
    begin
      TapeAutoLoad := not TapeAutoLoad;
      Sender.Value := BoolToStr(TapeAutoLoad, 'yes', 'no');
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

{ The joystick bindings, one line each, every line a page that waits for the
  key to bind. The control a line stands for is in its Data, so one handler
  serves all six. }
procedure TApplication.AddControlsPage(AParent: TMenuItem);
var
  Page, Item: TMenuItem;
  Control: TJoystickControl;
begin
  Page := AParent.AddItem('Joystick Controls');

  for Control := Low(TJoystickControl) to High(TJoystickControl) do
  begin
    Item := Page.AddKey(JoystickControlNames[Control],
      $'Press the key for {JoystickControlNames[Control]}:',
      procedure(Sender: TKeyMenuItem; AKey: TKeyboardKey)
      begin
        TJoystick.Bind(TJoystickControl(StrToInt(Sender.Data)), AKey);
        { Bind may have taken the key off whichever control had it before, so
          the whole page is refreshed rather than just this line. }
        RefreshControls(Sender.Parent);
      end);
    Item.Data := IntToStr(Ord(Control));
  end;

  Page.AddItem('Defaults', '',
    procedure(Sender: TMenuItem)
    begin
      TJoystick.ResetBindings;
      RefreshControls(Sender.Parent);
    end);

  RefreshControls(Page);
end;

{ Puts the bindings as they now stand back on the page's lines - both what the
  list shows and what each capture page shows while it waits. }
procedure TApplication.RefreshControls(APage: TMenuItem);
var
  I: Integer;
  Item: TMenuItem;
begin
  for I := 0 to APage.Items.Count - 1 do
  begin
    Item := APage.Items[I];
    if Item is TKeyMenuItem then
      Item.Value := TKeyboard.KeyName[
        TJoystick.Bindings[TJoystickControl(StrToInt(Item.Data))]];
  end;
end;

{ Opens the menu, which is also what pauses the machine. ACatalog starts it on
  the Catalog page instead of the top one. }
procedure TApplication.OpenMenu(ACatalog: Boolean);
begin
  Menu := BuildMenu;
  Menu.OnClose := procedure(ASender: TMenu; AQuit: Boolean)
    begin
      FreeAndNil(Menu);
      { The ENTER that chose an item is still down, and the machine is about to
        run again in this same frame. }
      Machine.Keyboard.SuppressUntilReleased(KEY_ENTER);
      { Nothing was generated while the menu was up. }
      PrimeAudio;
    end;

  { An empty catalog has no page to show, and Show ignores it. }
  if ACatalog then Menu.Show(FCatalogPage);
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
  begin
    PlayAudioStream(AudioStream);
    PrimeAudio;
    { The device may have been idle long enough to have been torn down; give it
      the same warm-up re-prime the initial start gets (see Run). }
    FAudioWarmup := GetTime + 0.75;
  end;
end;

procedure TApplication.SetTapeAutoLoad(AValue: Boolean);
begin
  if FTapeAutoLoad = AValue then Exit;
  FTapeAutoLoad := AValue;

  { give the ROM time (100 frames = 2 sec) to finish booting to BASIC first }
  AutoLoadFrame := if FTapeAutoLoad then 100 else -1;
end;

procedure TApplication.Run;
var
  Error: String;
  Requested: Boolean;
  {$ifdef USE_DELAY}
    FrameTime, Delta: Double;
  {$endif}
begin
  Machine.Power := True;

  if ParamCount > 0 then TapeFile := ParamStr(1);
  Requested := not TapeFile.IsEmpty;

  if Requested then
  begin
    { A bare name on the command line means a TapeFile. }
    if TPath.GetExtension(TapeFile).IsEmpty then TapeFile := TapeFile + '.z80';
    if not LoadFile(TapeFile, Error) then
    begin
      SetOSD($'{TPath.GetFileName(TapeFile)}: {Error}', 5);
      TapeFile := '';
    end;
  end;

  if not Muted then
  begin
    PlayAudioStream(AudioStream);
    PrimeAudio;

    { The fill above lands before the device has actually started pulling from
      the stream - on Linux the backend takes a beat to come up, and on top of
      that the first second carries the ROM's RAM test and one-off shader/font
      setup, so several early frames overshoot. Between them the stream is left
      running on a single sub-buffer at a phase where ordinary jitter clips a
      chunk about once a second - a steady stutter until something re-primes it
      (opening and closing the menu was the accidental cure). So schedule one
      more prime once the device is up and the frame clock has settled, which
      rebuilds the full two-sub-buffer cushion and holds. macOS and Windows do
      not need it but are not harmed by it. }
    FAudioWarmup := GetTime + 0.75;
  end;

  { Nothing asked for on the command line and something to offer: the session
    starts at the catalog rather than at a bare BASIC prompt. A file that was
    asked for and failed does not - its error is what the screen has to say. }
  if not Requested and not Catalog.IsEmpty then OpenMenu(True);

  SetExitKey(KEY_NULL);

  {$ifdef USE_DELAY}
    FrameTime := GetTime;
  {$endif}

  while not (WindowShouldClose or QuitRequested) do
  begin
    { The one-shot warm-up prime (see above). Skipped while the menu holds the
      machine paused - the stream is draining then, and its own OnClose primes
      it on the way out. }
    if (FAudioWarmup > 0) and (GetTime >= FAudioWarmup) then
    begin
      FAudioWarmup := 0;
      if not Paused and not Muted then PrimeAudio;
    end;

    RunFrame;
    if Turbo then Continue;

    {$ifdef USE_DELAY}
      FrameTime := FrameTime + (1 / FPS);

      { The schedule is absolute, so a frame that overshoots is made up by the
        next one rather than pushing every later frame back - that is what
        keeps the emulator's sample clock in step with the audio device. A long
        stall (dragging the window, a modal browser, a slow load) leaves the
        schedule far enough behind that making it up means running uncapped
        until it catches up: video at several times speed, and samples produced
        faster than the device drains them until the stream overflows. Past a
        whole frame of debt, write it off and start again from now. }
      if GetTime - FrameTime > (1 / FPS) then FrameTime := GetTime;

      Delta := (1 / FPS) - GetTime + FrameTime;
      if Delta > 0 then Delay(Delta);
    {$endif}
  end;

  StopAudioStream(AudioStream);
end;

procedure TApplication.HandleInput;
var
  Filename, FullFilename: String;
  I: Integer;
begin
  if IsKeyPressed(KEY_F10) then Fullscreen := not Fullscreen;

  if IsKeyPressed(KEY_SCROLL_LOCK) then
  begin
    Filename := TPath.GetFileNameWithoutExtension(CurrentFile);
    if Filename.IsEmpty then Filename := 'screen';
    FullFilename := Filename + '.png';
    I := 0;
    while TFile.Exists(FullFilename) and (I < 100) do
    begin
      Inc(I);
      FullFilename := $'{Filename}_{I}.png';
    end;
    ExportImage(Image, PChar(FullFilename));
    SetOSD(PChar('Saved ' + FullFilename));
  end;

  if Assigned(Menu) then
  begin
    Menu.HandleInput;
    Exit;
  end
  else if IsKeyPressed(KEY_ESCAPE) then
    if FQuitTimer.Enabled then
      QuitRequested := True
    else
    begin
      FQuitTimer.Enabled := True;
      FQuitTimer.Countdown := 2;
      SetOSD('ESC again to quit');
    end;

  if IsKeyPressed(KEY_F1) then OpenMenu;

  { Straight to the catalog, skipping the top page. Nothing to show means
    nothing happens, rather than the menu opening on something else. }
  if IsKeyPressed(KEY_TAB) and not Catalog.IsEmpty then OpenMenu(True);

  Turbo := IsKeyDown(KEY_GRAVE);

  if IsKeyPressed(KEY_F9) then ShowKeyboard := not ShowKeyboard;

  if IsKeyPressed(KEY_F2) then
  begin
    QuickSave;
    SetOSD('Saved');
  end;

  if IsKeyPressed(KEY_F3) and QuickLoad then
    SetOSD('Loaded');

  if IsKeyPressed(KEY_F7) or IsKeyPressed(KEY_F8) then
  begin
    if IsKeyDown(KEY_LEFT_SHIFT) or IsKeyDown(KEY_LEFT_SHIFT) then
    begin
      Overscan := Overscan + IfThen(IsKeyPressed(KEY_F7), -1, 1);
      SetOSD($'Overscan: {Overscan}');
    end else
    begin
      SetVolume(AudioVolume + IfThen(IsKeyPressed(KEY_F7), -0.05, 0.05));
      SetOsd($'Volume: {AudioVolume * 100:%.0f}');
    end;
  end;

  if IsKeyPressed(KEY_F11) then
  begin
    TVType := (TVType + 1) mod Length(Shaders);
    SetOSD($'TV-set: {TVTypeNames[TVType]}');
  end;

  if IsKeyPressed(KEY_F6) then
  begin
    Machine.SwitchJoystick;
    SetOSD($'Joystick: {Machine.JoystickName}');
  end;

  if IsKeyPressed(KEY_F5) and Machine.WavLoaded then
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

{ Refills the stream so playback resumes on a full cushion. Nothing else
  rebuilds one: in steady state the device drains a chunk in exactly the time
  the emulator takes to produce one, so a stream that has been emptied - by the
  menu being open, by a mute, by a minimised window, by a stall - comes back
  with a single chunk of margin and stays there, and ordinary jitter then takes
  it under several times a second for the rest of the session. Only sub-buffers
  the device has finished with are filled, so this does nothing to a stream that
  is already full. }
procedure TApplication.PrimeAudio;
var
  I: Integer;
begin
  if not IsAudioStreamValid(AudioStream) then Exit;

  FillByte(AccumBuf, SizeOf(AccumBuf), 0); { 0 = silence for signed 16-bit PCM }
  AccumPos := 0;

  { The stream is two sub-buffers deep, so a third pass could never be taken. }
  for I := 1 to 2 do
    if IsAudioStreamProcessed(AudioStream) then
      UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);
end;

procedure TApplication.RenderAudioFrame;
var
  Accepted, Starved: Boolean;
  {$ifdef DEBUG_AUDIO}
    Started, Updated: Double;
  {$endif}
begin
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
    {$ifdef DEBUG_AUDIO}
      { A chunk the stream is too busy to take is dropped on the floor, silently
        losing AudioChunkFrames' worth of audio - the instrumentation counts
        those, since each one is a discontinuity the speaker reproduces as a
        click. Timing the handoff itself catches the other case, where the call
        blocks behind the device thread. }
      Started := GetTime;
      {$endif}
    Accepted := IsAudioStreamProcessed(AudioStream);
    if Accepted then
      UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);
    {$ifdef DEBUG_AUDIO}
      Updated := GetTime;
    {$endif}

    { The stream holds two sub-buffers. One having just been filled, a stream
      that still reports a processed sub-buffer has the other one free as well
      - the device had already drained everything and played silence into the
      gap. That is the underrun the drop count above cannot see, and it does not
      pass: producer and device are rate matched, so margin the stream loses it
      never wins back, and it would go on running dry several times a second for
      the rest of the session. The gap has already been heard by the time we get
      here, so putting silence in the spare sub-buffer costs nothing further and
      restores the cushion. }
    Starved := Accepted and IsAudioStreamProcessed(AudioStream);

    AccumPos := 0;
    if Starved then PrimeAudio;

    {$ifdef DEBUG_AUDIO}
      StatsChunk(Accepted, Starved, (Updated - Started) * 1000);
    {$endif}
  end;
end;

procedure TApplication.SaveConfig;
var
  Control: TJoystickControl;
begin
  if not Assigned(Config) then Exit;

  Config.WriteBool('Window', 'Fullscreen', Fullscreen);
  if not Fullscreen then
  begin
    Config.WriteInteger('Window', 'Width', GetScreenWidth);
    Config.WriteInteger('Window', 'Height', GetScreenHeight);
  end;

  Config.WriteInteger('Display', 'TVType', TVType);
  Config.WriteInteger('Display', 'Overscan', Overscan);
  Config.WriteBool('Display', 'Aspect', Aspect);
  Config.WriteFloat('Display', 'Curvature', Curvature);

  Config.WriteFloat('Audio', 'Volume', AudioVolume);
  Config.WriteBool('Audio', 'Muted', Muted);
  Config.WriteBool('Tape', 'AutoLoad', TapeAutoLoad);
  Config.WriteBool('Tape', 'Sound', TapeSound);
  Config.WriteBool('Tape', 'Save', Machine.SaveToWav);

  Config.WriteInteger('Joystick', 'Index', Machine.JoystickIndex);

  for Control := Low(TJoystickControl) to High(TJoystickControl) do
    Config.WriteString('Joystick', JoystickControlNames[Control],
      TKeyboard.KeyId[TJoystick.Bindings[Control]]);
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

