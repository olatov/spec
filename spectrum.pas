unit Spectrum;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, System.IOUtils,
  Raylib,
  Z80;

type
  TZXColorIndex = 0..15;

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

  TAdvanceAudioNotify = procedure(ANewT: Integer) of object;
  TTapeSavedNotify = procedure(const AFilename: String) of object;

  TZXSpectrum48 = class
  private
    FBorderColorIndex: TZXColorIndex;
    FContended: Boolean;
    FCurrentScanline: Integer;
    FCycles: QWord;
    FFlashPhase: Boolean;
    FOvershoot: Integer;
    FFrames: QWord;
    FINT: Boolean;
    FPower: Boolean;
    FTotalTStates: QWord;
    { .TAP fast-load trap state. }
    FTapeBlocks: array of TBytes;
    FTapeCursor: Integer;
    FTapeLoaded: Boolean;
    { .WAV real-time EAR-line playback. FWavEdges holds the cumulative,
      tape-relative T-state of every signal transition; the level between
      edge i-1 and edge i is FWavStartLevel xor Odd(i). }
    FWavEdges: array of QWord;
    FWavStartLevel: Boolean;
    FWavCursor: Integer;
    FWavLoaded: Boolean;
    FTapePlaying: Boolean;
    FTapeArmed: Boolean;         { auto-play on the next EAR read (set on LD-BYTES entry) }
    FTapeLoading: Boolean;       { inside LD-BYTES - never auto-pause here }
    FTapeBaseTState: QWord;      { machine T-state that maps to tape position 0 }
    FFrameBaseTState: QWord;     { FTotalTStates at the current frame's start, so the
                                   frame-relative T-states the audio mixer works in can
                                   be resolved against the tape clock }
    FTapePausedT: QWord;         { tape-relative T-state to resume playback from }
    FTapeLastEarFrame: QWord;    { frame number of the most recent EAR poll }
    { SAVE capture: the ROM's real SA-BYTES runs and toggles the MIC line; we
      timestamp every transition and render the result as a .WAV. }
    FSaveEnabled: Boolean;
    FSaveEdges: array of QWord;  { absolute machine T-states of MIC transitions }
    FSaveCount: Integer;
    FSaveStartLevel: Boolean;
    FSaveArmed: Boolean;         { SA-BYTES seen, waiting for the first MIC edge }
    FSaveRecording: Boolean;
    FSaveLastEdgeFrame: QWord;
    FSaveName: String;
    procedure ArmSave;
    procedure RecordMicEdge;
    procedure FinishSave;
    function WriteSaveWAV(const AFilename: String): Boolean;
    { Picks the output path from the Spectrum filename captured at SA-BYTES,
      falling back to a generic name, and never overwrites an existing file. }
    function SaveOutputPath: String;
    procedure SetBorderColorIndex(AValue: TZXColorIndex);
    procedure SetINT(AValue: Boolean);
    procedure SetPower(AValue: Boolean);
    function GetTapeBlockCount: Integer;
    { Standard fast-load trap for LD-BYTES ($0556): consumes the next tape
      block per the routine's entry/exit register contract, then simulates
      the RET back to SA_LD_RET that the real routine would perform. Runs as
      an instantaneous trap, not real bus activity. }
    procedure HandleLoadTrap;
    { Absolute monotonic T-state, valid inside any CPU callback (z80_run
      resets CPU.cycles per call and FTotalTStates excludes the in-progress
      Tick). }
    function CurrentTStates: QWord;
    function WavLengthTStates: QWord;
    function FindWavEdge(ATapeT: QWord): Integer;
    procedure SeekWavCursor(ATapeT: QWord);
    { Current tape signal level; also drives auto start/stop. Call once per
      genuine ULA read of port $FE. }
    function TapeEar: Boolean;
  public
    CPU: TZ80;
    ROM: array[0..$3FFF] of Byte;
    RAM: array[$4000..$FFFF] of Byte;
    AudioPin: Boolean;
    MicPin: Boolean;      { port $FE bit 3 - what SAVE modulates }
    Joystick: TJoystick;
    AdvanceAudio: TAdvanceAudioNotify;
    OnTapeSaved: TTapeSavedNotify;
    function OnMemoryRead(AAddress: Word): Byte;
    procedure OnMemoryWrite(AAddress: Word; AValue: Byte);
    function OnIORead(AAddress: Word): Byte;
    procedure OnIOWrite(AAddress: Word; AValue: Byte);
    function OnHook(AAddress: Word): Byte;
    property Contended: Boolean read FContended;
    property FlashPhase: Boolean read FFlashPhase;
    property CurrentScanline: Integer read FCurrentScanline;
    property BorderColorIndex: TZXColorIndex read FBorderColorIndex write SetBorderColorIndex;
    property Frames: QWord read FFrames;
    property Cycles: QWord read FCycles;
    property Power: Boolean read FPower write SetPower;
    property INT: Boolean read FINT write SetINT;
    property TapeCursor: Integer read FTapeCursor;
    property TapeBlockCount: Integer read GetTapeBlockCount;
    property WavLoaded: Boolean read FWavLoaded;
    property TapePlaying: Boolean read FTapePlaying;
    { True while a SAVE is streaming out - drives the speaker mix. }
    property Saving: Boolean read FSaveRecording;
    { Whether a completed SAVE is written out as a .WAV. The MIC line is
      captured (and heard) either way. }
    property SaveToWav: Boolean read FSaveEnabled write FSaveEnabled;
    constructor Create;
    procedure Reset;
    procedure Wait(ACycles: Integer);
    procedure Tick(ACycles: Integer);
    procedure BeginFrame;
    procedure RunScanline;
    procedure LoadZ80(AFilename: String);
    procedure LoadZ80(AStream: TStream);
    procedure SaveZ80(AFilename: String);
    procedure SaveZ80(AStream: TStream);
    { Parses a .TAP file into tape blocks, verbatim (flag byte + data +
      checksum byte per block, exactly as LD-BYTES expects to stream them),
      resets the block cursor, and patches the ROM's LD-BYTES entry so the
      fast-load trap fires. Returns False (leaving the tape empty and the ROM
      unpatched) if the file can't be read or contains no blocks. }
    function LoadTAP(const AFilename: String): Boolean;
    { Decodes a PCM .WAV file (8/16-bit, mono or stereo) into a transition
      list for real-time playback on the EAR line, and patches LD-BYTES so
      playback auto-starts when a load begins. The ROM (or a turbo loader)
      times the edges itself. Returns False if the file isn't a usable PCM
      WAV or decodes to no signal. }
    function LoadWAV(const AFilename: String): Boolean;
    procedure TapePlay;
    procedure TapePause;
    procedure TapeStop;   { pause and rewind to the start }
    { HIGH duty cycle of the tape signal over a span of the current frame, for
      mixing the loading noise into the speaker. }
    function TapeHighTStates(AFromT, AToT: Integer): Integer;
    function TapePositionSeconds: Double;
    function TapeLengthSeconds: Double;
  end;

{$embedbytes ROMBytes 'rom/48.rom'}

implementation

const
  { Entry points of the 48K ROM's tape routines. }
  LDBytesAddress = $0556;
  SABytesAddress = $04C2;
  { SA/LD-RET - the return address LD-BYTES and SA-BYTES push for themselves,
    so reaching it means the tape operation is over. }
  SALDRetAddress = $053F;

  { Sample rate of the .WAV files SAVE produces. }
  WavSampleRate = 44100;

  { 48K Spectrum CPU clock - the timebase the tape edge list is expressed in. }
  CPUClockHz = 3500000;

  { Auto-pause the WAV tape after this many frames without an EAR poll, so it
    holds position through inter-block gaps and menu screens instead of running
    past the next block's pilot tone. Only consulted between blocks: LD-BYTES's
    own LD-WAIT settle ($0571) spins for 1.00s - 50.2 frames - touching no I/O,
    which would otherwise trip any threshold near a second and strand the deck
    mid-pilot. FTapeLoading suppresses the timeout for exactly that window. }
  TapeSilenceFrames = 50;

  { A SAVE is finished once MIC has been quiet this long. Must exceed the
    ROM's own 1-second (50 frame) pause between the header and data blocks,
    or each SAVE would land in two separate files. }
  SaveSilenceFrames = 100;

  EarBit = %01000000;

function FetchCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnMemoryRead(Address);
end;

procedure WriteCallback(Context: Pointer; Address: UInt16; Value: UInt8); cdecl;
begin
  TZXSpectrum48(Context).OnMemoryWrite(Address, Value);
end;

function NMIACallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := $FF;
end;

function INTACallback(Context: Pointer; address: UInt16): UInt8; cdecl;
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

function INTFetchCallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function IllegalCallback(cpu: PZ80; opcode: UInt8): UInt8; cdecl;
begin
  Result := 0;
end;

procedure LDIACallback(Context: Pointer); cdecl;
begin

end;

procedure LDRACallback(Context: Pointer); cdecl;
begin

end;

procedure RETICallback(Context: Pointer); cdecl;
begin

end;

procedure RETNCallback(Context: Pointer); cdecl;
begin

end;

procedure HaltCallback(Context: Pointer; state: UInt8); cdecl;
begin

end;

function NopCallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function HookCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnHook(Address);
end;

function InputCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnIORead(Address);
end;

procedure OutputCallback(Context: Pointer; Address: UInt16; Value: UInt8); cdecl;
begin
  TZXSpectrum48(Context).OnIOWrite(Address, Value);
end;

procedure TZXSpectrum48.SetPower(AValue: Boolean);
begin
  if FPower = AValue then Exit;
  FPower := AValue;
  z80_power(@CPU, AValue);
end;

function TZXSpectrum48.OnMemoryRead(AAddress: Word): Byte; inline;
begin
  Result := if AAddress < $4000
    then ROM[AAddress]
    else RAM[AAddress];

  if Contended and InRange(AAddress, $4000, $7FFF) then Wait(2);
end;

procedure TZXSpectrum48.OnMemoryWrite(AAddress: Word; AValue: Byte); inline;
begin
  if AAddress >= $4000 then RAM[AAddress] := AValue;
  if Contended and InRange(AAddress, $4000, $7FFF) then Wait(2);
end;

function TZXSpectrum48.OnIORead(AAddress: Word): Byte;
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
  Result := $FF;

  if not AAddress.Bits[0] then
  begin
    if Contended then Wait(2);
    Result := Result and PollKeyboard(Hi(AAddress));

    { EAR (bit 6): fed from the WAV tape while one is loaded, so the ROM /
      turbo loader can time the edges. Overrides the idle "no signal" 1. }
    if FWavLoaded then
      if TapeEar then
        Result := Result or EarBit
      else
        Result := Result and not Byte(EarBit);
  end;

  if not AAddress.Bits[5] then
    Result := Result and PollKempston;
end;

procedure TZXSpectrum48.OnIOWrite(AAddress: Word; AValue: Byte); inline;
begin
  case AAddress.Bytes[0] of
    $FE:
      begin
        BorderColorIndex := AValue and %111;
        { Flush the audio bucket before either pin moves - this same write is
          the only thing that can move them. }
        if Assigned(AdvanceAudio) then AdvanceAudio(Cycles + CPU.cycles);
        AudioPin := AValue.Bits[4];

        if AValue.Bits[3] <> MicPin then
        begin
          MicPin := AValue.Bits[3];
          if FSaveArmed or FSaveRecording then RecordMicEdge;
        end;
      end;
  end;
end;

function TZXSpectrum48.OnHook(AAddress: Word): Byte;
begin
  if AAddress = LDBytesAddress then
  begin
    if FWavLoaded then
    begin
      { WAV mode: the real LD-BYTES has to run, polling the EAR line and
        timing the edges itself. The hook is only a tripwire telling us a
        load has begun, so the tape auto-plays from here.

        Returning the displaced opcode (rather than Z80_HOOK) makes the
        core dispatch it from its own instruction table - see hook's INSN
        in Z80.c. That matters: the displaced opcode is INC D, which is in
        LD-BYTES purely to reset the Z flag before EX AF,AF' banks the
        flags away, and $05A9 later reads that Z flag back to tell "still
        on the flag byte" from "into the data". Re-creating the INC in
        Pascal would move D without moving the flags, and every block's
        flag byte would be misrouted.

        Read from ROMBytes, not ROM[] - the latter holds the hook byte. }
      FTapeArmed := True;
      FTapeLoading := True;
      Exit(ROMBytes[LDBytesAddress]);
    end;

    HandleLoadTrap;

    { The Z80 core treats the hook's return value as a fresh opcode to
      dispatch immediately UNLESS it's Z80_HOOK (see hook's INSN in
      Z80.c) - returning Z80_HOOK is what tells it "the hook fully
      replaced this instruction", leaving `pc` exactly where
      HandleLoadTrap's RET simulation set it, instead of also executing
      one stray extra instruction there first. }
    Result := Z80_HOOK;
  end
  else if AAddress = SALDRetAddress then
  begin
    { LD-BYTES / SA-BYTES have returned, so the idle timeout may pause the
      deck again. Its displaced opcode is PUSH AF. }
    FTapeLoading := False;
    Result := ROMBytes[SALDRetAddress];
  end
  else if AAddress = SABytesAddress then
  begin
    { SAVE tripwire. Like the WAV load hook this only watches - the real
      SA-BYTES runs and modulates MIC itself, so custom savers and the ROM
      alike come out right. Its displaced opcode is LD HL,$053F, whose
      operand bytes are still in place at $04C3/$04C4. }
    ArmSave;
    Result := ROMBytes[SABytesAddress];
  end
  else
    { Not our trap address - this is a real (if useless) LD H,H
      instruction elsewhere; let it behave as a harmless NOP rather than
      swallowing it as Z80_HOOK, which would leave `pc` stuck unadvanced. }
    Result := Z80_NOP;
end;

procedure TZXSpectrum48.SetINT(AValue: Boolean);
begin
  if FINT = AValue then Exit;
  FINT := AValue;
  z80_int(@CPU, AValue);
end;

procedure TZXSpectrum48.SetBorderColorIndex(AValue: TZXColorIndex); inline;
begin
  if FBorderColorIndex = AValue then Exit;
  FBorderColorIndex := AValue and %111;
end;

constructor TZXSpectrum48.Create;
begin
  with CPU do
  begin
    fetch := @FetchCallback;
    fetch_opcode := @FetchCallback;
    halt := @HaltCallback;
    read := @FetchCallback;
    write := @WriteCallback;
    hook := @HookCallback;
    input := @InputCallback;
    output := @OutputCallback;
    nop := @NopCallback;
    nmia := @NMIACallback;
    inta := @INTACallback;
    int_fetch := @INTFetchCallback;
    ld_i_a := @LDIACallback;
    ld_r_a := @LDRACallback;
    reti := @RETICallback;
    retn := @RETNCallback;
    illegal := @IllegalCallback;
    context := Self;
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

  Reset;
end;

procedure TZXSpectrum48.Reset;
begin
  FFrames := 0;
  FCycles := 0;
  FTotalTStates := 0;
  Move(ROMBytes, ROM, SizeOf(ROMBytes));

  { A fresh ROM image loses the tape patches; reapply them. The SA-BYTES
    tripwire is unconditional - it costs nothing when nothing is saving. }
  if FTapeLoaded or FWavLoaded then ROM[LDBytesAddress] := Z80_HOOK;
  if FWavLoaded then ROM[SALDRetAddress] := Z80_HOOK;
  ROM[SABytesAddress] := Z80_HOOK;

  { The tape clock is tied to FTotalTStates, which just restarted. }
  FTapePlaying := False;
  FTapeArmed := False;
  FTapeLoading := False;
  FTapeBaseTState := 0;
  FTapePausedT := 0;
  FWavCursor := 0;

  CPU.pc.word := 0;
end;

procedure TZXSpectrum48.Wait(ACycles: Integer); inline;
begin
  Inc(CPU.cycles, ACycles);
end;

procedure TZXSpectrum48.Tick(ACycles: Integer); inline;
var
  Requested, Fact: Integer;
begin
  Requested := Max(ACycles - FOvershoot, 0);
  Fact := z80_run(@CPU, Requested);
  FOvershoot := Fact - Requested;
  Inc(FCycles, Fact);
  Inc(FTotalTStates, Fact);
  { z80_run leaves its own count in CPU.cycles, which FTotalTStates has now
    absorbed. Clear it so CurrentTStates stays right outside a callback too -
    z80_run zeroes it on entry, so this costs the CPU core nothing. }
  CPU.cycles := 0;
end;

procedure TZXSpectrum48.RunScanline; inline;
const
  INTLine = 295; { Has to be 64 line times before the first byte
                   of the screen (16384) is displayed. }
begin
  case FCurrentScanline of
    47..239:
      begin
        FContended := True;
        Tick(128);
        FContended := False;
        Tick(96);
      end;

    INTLine:
      begin
        INT := True;
        Tick(32);
        INT := False;
        Tick(192);
    end;

  else
    Tick(224);
  end;

  Inc(FCurrentScanline);
end;

procedure TZXSpectrum48.LoadZ80(AFilename: String);
var
  Stream: TFileStream;
begin
  Stream := autofree TFile.OpenRead(AFilename);
  LoadZ80(Stream);
end;

procedure TZXSpectrum48.BeginFrame;
begin
  FCycles := 0;
  FFrameBaseTState := FTotalTStates;
  Inc(FFrames);
  FCurrentScanline := 0;
  FFlashPhase := Odd(Frames div 16);

  if FTapePlaying and not FTapeLoading
    and (FFrames - FTapeLastEarFrame > TapeSilenceFrames) then
      TapePause;

  if FSaveRecording and (FFrames - FSaveLastEdgeFrame > SaveSilenceFrames) then
    FinishSave;
end;

procedure TZXSpectrum48.LoadZ80(AStream: TStream);
var
  Data, ExtData: Byte;
  Addr: Integer;
  Compressed: Boolean;
  PC1: UInt16;
  HeaderLen: UInt16;
  HWMode: Byte;
  BlockLen: UInt16;
  PageNum: Byte;
  BlockEnd: Int64;

  { Decompresses a run of ED-ED-count-value encoded bytes from Stream into
    Memory, starting at StartAddr, until Stream.Position reaches EndPos.
    StartAddr < 0 means "discard" (used to skip unsupported 128K pages). }
  procedure DecodeBlock(StartAddr: Integer; EndPos: Int64);
  var
    CurAddr, I: Integer;
  begin
    CurAddr := StartAddr;
    while AStream.Position < EndPos do
    begin
      Data := AStream.ReadByte;
      if Data = $ED then
      begin
        ExtData := AStream.ReadByte;
        if ExtData = $ED then
        begin
          Data := AStream.ReadByte;
          ExtData := AStream.ReadByte;
          for I := 1 to Data do
          begin
            if CurAddr >= 0 then RAM[CurAddr] := ExtData;
            Inc(CurAddr);
          end;
        end else
        begin
          if CurAddr >= 0 then
          begin
            RAM[CurAddr] := Data;
            RAM[CurAddr + 1] := ExtData;
          end;
          Inc(CurAddr, 2);
        end;
      end else
      begin
        if CurAddr >= 0 then RAM[CurAddr] := Data;
        Inc(CurAddr);
      end;
    end;
  end;

begin
  Reset;

  CPU.af.bytes.high := AStream.ReadByte;
  CPU.af.bytes.low := AStream.ReadByte;
  CPU.bc.word := AStream.ReadWord;
  CPU.hl.word := AStream.ReadWord;
  PC1 := AStream.ReadWord; { 0 here means this is actually a v2/v3 snapshot }
  CPU.sp.word := AStream.ReadWord;
  CPU.i := AStream.ReadByte;
  CPU.r := AStream.ReadByte;

  Data := AStream.ReadByte;
  CPU.r.Bits[7] := Data.Bits[0];
  BorderColorIndex := (Data shr 1) and %111;
  Compressed := Data.Bits[5];

  CPU.de.word := AStream.ReadWord;
  CPU.bc_.word := AStream.ReadWord;
  CPU.de_.word := AStream.ReadWord;
  CPU.hl_.word := AStream.ReadWord;
  CPU.af_.bytes.high := AStream.ReadByte;
  CPU.af_.bytes.low := AStream.ReadByte;
  CPU.ix_iy[1].word := AStream.ReadWord;
  CPU.ix_iy[0].word := AStream.ReadWord;

  CPU.iff1 := AStream.ReadByte; { Interrupt flipflop, 0=DI, otherwise EI }
  CPU.iff2 := AStream.ReadByte; { IFF2 (not particularly important...) }
  CPU.im := AStream.ReadByte and %11;

  if PC1 <> 0 then
  begin
    { Version 1: PC sits in the base header, and one flat block holds the
      whole 48K RAM image. }
    CPU.pc.word := PC1;

    if Compressed then
      DecodeBlock(16384, AStream.Size - 4)
    else
      AStream.Read(RAM[16384], AStream.Size - AStream.Position);
  end else
  begin
    { Version 2/3: PC=0 in the base header is the marker that an extended
      header follows, holding the real PC, then memory arrives as separate
      page-numbered blocks rather than one flat image. The "Compressed" flag
      read above is a v1-only field and has no meaning here - each block
      carries its own length instead. }
    HeaderLen := AStream.ReadWord;
    CPU.pc.word := AStream.ReadWord;
    HWMode := AStream.ReadByte;
    AStream.Position := AStream.Position + (HeaderLen - 3);

    while AStream.Position < AStream.Size do
    begin
      BlockLen := AStream.ReadWord;
      PageNum := AStream.ReadByte;

      { 48K page numbering; other pages are 128K banks / ROM, unsupported
        by this emulator's flat memory model, so they're skipped. }
      case PageNum of
        4: Addr := $8000;
        5: Addr := $C000;
        8: Addr := $4000;
        else Addr := -1;
      end;

      if BlockLen = $FFFF then
      begin
        { Uncompressed 16K page }
        if Addr >= 0 then
          AStream.Read(RAM[Addr], 16384)
        else
          AStream.Position := AStream.Position + 16384;
      end else
      begin
        BlockEnd := AStream.Position + BlockLen;
        DecodeBlock(Addr, BlockEnd);
      end;
    end;
  end;
end;

procedure TZXSpectrum48.SaveZ80(AFilename: String);
var
  Stream: TFileStream;
begin
  Stream := autofree TFile.OpenOrCreate(AFilename);
  SaveZ80(Stream);
end;

procedure TZXSpectrum48.SaveZ80(AStream: TStream);
var
  Data: Byte = 0;
begin
  with AStream do
  begin
    WriteByte(CPU.af.bytes.high);
    WriteByte(CPU.af.bytes.low);
    WriteWord(CPU.bc.word);
    WriteWord(CPU.hl.word);
    WriteWord(CPU.pc.word);
    WriteWord(CPU.sp.word);
    WriteByte(CPU.i);
    WriteByte(CPU.r);

    Data.Bits[0] := CPU.r.Bits[7];
    Data := Data or (BorderColorIndex shl 1);
    Data.Bits[5] := False;  { Uncompressed }
    WriteByte(Data);

    WriteWord(CPU.de.word);
    WriteWord(CPU.bc_.word);
    WriteWord(CPU.de_.word);
    WriteWord(CPU.hl_.word);
    WriteByte(CPU.af_.bytes.high);
    WriteByte(CPU.af_.bytes.low);
    WriteWord(CPU.ix_iy[1].word);
    WriteWord(CPU.ix_iy[0].word);

    WriteByte(CPU.iff1);
    WriteByte(CPU.iff2);
    WriteByte(CPU.im);

    WriteBuffer(RAM, SizeOf(RAM));
  end;
end;

function TZXSpectrum48.GetTapeBlockCount: Integer;
begin
  Result := Length(FTapeBlocks);
end;

function TZXSpectrum48.LoadTAP(const AFilename: String): Boolean;
var
  FS: TFileStream;
  LenLo, LenHi: Byte;
  Len: Word;
  Block: TBytes;
begin
  SetLength(FTapeBlocks, 0);
  FTapeCursor := 0;
  FTapeLoaded := False;
  Result := False;

  if not TFile.Exists(AFilename) then Exit;

  FS := autofree TFile.OpenRead(AFilename);
  while FS.Position < FS.Size do
  begin
    if (FS.Read(LenLo, 1) <> 1) or (FS.Read(LenHi, 1) <> 1) then Break;
    Len := LenLo or (Word(LenHi) shl 8);
    if Len = 0 then Continue;

    SetLength(Block, Len);
    if FS.Read(Block[0], Len) <> Len then Break;

    SetLength(FTapeBlocks, Length(FTapeBlocks) + 1);
    FTapeBlocks[High(FTapeBlocks)] := Block;
  end;

  Result := Length(FTapeBlocks) > 0;
  if Result then
  begin
    FTapeLoaded := True;
    ROM[LDBytesAddress] := Z80_HOOK;

    { A .TAP replaces any WAV tape - the two loaders are mutually exclusive.
      The SA/LD-RET tripwire is WAV-only, so hand that byte back. }
    FWavLoaded := False;
    FTapePlaying := False;
    FTapeArmed := False;
    FTapeLoading := False;
    ROM[SALDRetAddress] := ROMBytes[SALDRetAddress];
    SetLength(FWavEdges, 0);
  end;
end;

procedure TZXSpectrum48.HandleLoadTrap;
var
  Block: TBytes;
  ExpectedFlag, Checksum: Byte;
  RequestedLen, ActualLen: Word;
  IsLoad, Ok: Boolean;
  I: Integer;
  RetLo, RetHi: Byte;
begin
  ExpectedFlag := CPU.af.bytes.high;
  IsLoad := (CPU.af.bytes.low and Z80_CF) <> 0;
  RequestedLen := CPU.de.word;
  Ok := False;

  if FTapeCursor < Length(FTapeBlocks) then
  begin
    Block := FTapeBlocks[FTapeCursor];
    Inc(FTapeCursor);
  end
  else
    SetLength(Block, 0);

  if (Length(Block) >= 2) and (Block[0] = ExpectedFlag) then
  begin
    Checksum := 0;
    for I := 0 to High(Block) do
      Checksum := Checksum xor Block[I];

    if Checksum = 0 then
    begin
      ActualLen := Length(Block) - 2; { minus flag byte and trailing checksum byte }
      if ActualLen > RequestedLen then ActualLen := RequestedLen;

      if IsLoad then
      begin
        for I := 0 to ActualLen - 1 do
          OnMemoryWrite(CPU.ix_iy[0].word + I, Block[1 + I]);
      end
      else
      begin
        Ok := True;
        for I := 0 to ActualLen - 1 do
          if OnMemoryRead(CPU.ix_iy[0].word + I) <> Block[1 + I] then
          begin
            Ok := False;
            Break;
          end;
      end;

      CPU.ix_iy[0].word := CPU.ix_iy[0].word + ActualLen;
      CPU.de.word := RequestedLen - ActualLen;

      Ok := (ActualLen = RequestedLen) and (IsLoad or Ok);
    end;
  end;

  if Ok then
    CPU.af.bytes.low := CPU.af.bytes.low or Z80_CF
  else
    CPU.af.bytes.low := CPU.af.bytes.low and not Z80_CF;

  { The caller (SAVE_ETC / LD_BLOCK) pushed SA_LD_RET before jumping here;
    simulate LD-BYTES's own RET back to it. }
  RetLo := OnMemoryRead(CPU.sp.word);
  RetHi := OnMemoryRead(CPU.sp.word + 1);
  CPU.sp.word := CPU.sp.word + 2;
  CPU.pc.word := RetLo or (Word(RetHi) shl 8);
end;

function TZXSpectrum48.CurrentTStates: QWord; inline;
begin
  Result := FTotalTStates + CPU.cycles;
end;

function TZXSpectrum48.WavLengthTStates: QWord;
begin
  if Length(FWavEdges) = 0 then
    Result := 0
  else
    Result := FWavEdges[High(FWavEdges)];
end;

{ Index of the first edge strictly after ATapeT. }
function TZXSpectrum48.FindWavEdge(ATapeT: QWord): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := Length(FWavEdges);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FWavEdges[Mid] <= ATapeT then Lo := Mid + 1 else Hi := Mid;
  end;
  Result := Lo;
end;

procedure TZXSpectrum48.SeekWavCursor(ATapeT: QWord);
begin
  FWavCursor := FindWavEdge(ATapeT);
end;

{ T-states the tape signal spent HIGH within [AFromT, AToT) of the current frame -
  i.e. the span's HIGH duty cycle, in the same currency the beeper mixer uses, so
  tape noise passes through the same boxcar low-pass instead of being point-sampled
  (which would alias the 2-3 kHz pulse train into whistles). Returns 0 unless a WAV
  tape is actually playing, and uses its own edge index so the CPU-facing FWavCursor
  is left alone. }
function TZXSpectrum48.TapeHighTStates(AFromT, AToT: Integer): Integer;
var
  A, B, SegStart: QWord;
  Idx: Integer;
  Level: Boolean;
begin
  Result := 0;
  if AToT <= AFromT then Exit;

  { Saving: MIC is a live pin that only moves on an OUT to $FE - the very
    write that flushes the audio bucket - so the span is a flat level and
    needs no edge walk. }
  if FSaveRecording then
  begin
    if MicPin then Result := AToT - AFromT;
    Exit;
  end;

  if not FTapePlaying then Exit;

  A := FFrameBaseTState + QWord(AFromT);
  B := FFrameBaseTState + QWord(AToT);

  { Anything before playback began is silence, not signal. }
  if A < FTapeBaseTState then A := FTapeBaseTState;
  if B <= A then Exit;

  Dec(A, FTapeBaseTState);
  Dec(B, FTapeBaseTState);

  Idx := FindWavEdge(A);
  Level := FWavStartLevel xor Odd(Idx);
  SegStart := A;

  while (Idx < Length(FWavEdges)) and (FWavEdges[Idx] < B) do
  begin
    if Level then Inc(Result, Integer(FWavEdges[Idx] - SegStart));
    SegStart := FWavEdges[Idx];
    Level := not Level;
    Inc(Idx);
  end;

  if Level then Inc(Result, Integer(B - SegStart));
end;

function TZXSpectrum48.TapeEar: Boolean;
var
  T: QWord;
begin
  FTapeLastEarFrame := FFrames;

  if FTapeArmed then
  begin
    FTapeArmed := False;
    TapePlay;
  end;

  if not FTapePlaying then Exit(False);

  T := CurrentTStates - FTapeBaseTState;

  while (FWavCursor < Length(FWavEdges)) and (FWavEdges[FWavCursor] <= T) do
    Inc(FWavCursor);

  if FWavCursor >= Length(FWavEdges) then
  begin
    TapeStop;
    Exit(False);
  end;

  Result := FWavStartLevel xor Odd(FWavCursor);
end;

procedure TZXSpectrum48.TapePlay;
begin
  if not FWavLoaded or FTapePlaying then Exit;

  if FTapePausedT >= WavLengthTStates then FTapePausedT := 0; { restart after the end }
  FTapeBaseTState := CurrentTStates - FTapePausedT;
  SeekWavCursor(FTapePausedT);
  FTapePlaying := True;
  FTapeLastEarFrame := FFrames;
end;

procedure TZXSpectrum48.TapePause;
begin
  if not FTapePlaying then Exit;
  FTapePausedT := CurrentTStates - FTapeBaseTState;
  FTapePlaying := False;
end;

procedure TZXSpectrum48.TapeStop;
begin
  FTapePlaying := False;
  FTapeArmed := False;
  FTapePausedT := 0;
  FWavCursor := 0;
end;

function TZXSpectrum48.TapePositionSeconds: Double;
var
  T: QWord;
begin
  if FTapePlaying then T := CurrentTStates - FTapeBaseTState
  else T := FTapePausedT;
  Result := T / CPUClockHz;
end;

function TZXSpectrum48.TapeLengthSeconds: Double;
begin
  Result := WavLengthTStates / CPUClockHz;
end;

{ SA-BYTES has been entered. Note the Spectrum filename while it's still in
  memory - a header block arrives with the flag byte $00 in A, 17 in DE and
  IX pointing at [type, name[10], ...] - then wait for MIC to start moving. }
procedure TZXSpectrum48.ArmSave;
var
  I: Integer;
  Ch: Char;
begin
  if not FSaveRecording then
  begin
    FSaveCount := 0;
    FSaveName := '';
  end;

  if (CPU.af.bytes.high = $00) and (CPU.de.word = 17) then
  begin
    for I := 1 to 10 do
    begin
      Ch := Char(OnMemoryRead(CPU.ix_iy[0].word + I));
      { Spectrum names may hold anything, including characters no filesystem
        will take; keep the safe ones and drop the rest. }
      if Ch in ['A'..'Z', 'a'..'z', '0'..'9', ' ', '-', '_', '.'] then
        FSaveName := FSaveName + Ch;
    end;
    FSaveName := FSaveName.Trim;
  end;

  FSaveArmed := True;
end;

procedure TZXSpectrum48.RecordMicEdge;
begin
  if not FSaveRecording then
  begin
    { The pin has just flipped, so the level held before this edge is the
      opposite of what it now reads. }
    FSaveStartLevel := not MicPin;
    FSaveRecording := True;
    FSaveArmed := False;
  end;

  FSaveLastEdgeFrame := FFrames;
  if not FSaveEnabled then Exit;   { still heard, just not written }

  if FSaveCount >= Length(FSaveEdges) then
    SetLength(FSaveEdges, Max(1024, Length(FSaveEdges) * 2));
  FSaveEdges[FSaveCount] := CurrentTStates;
  Inc(FSaveCount);
end;

function TZXSpectrum48.SaveOutputPath: String;
var
  Base: String;
  N: Integer;
begin
  Base := if FSaveName <> '' then FSaveName else 'spec-save';
  Result := Base + '.wav';

  N := 1;
  while TFile.Exists(Result) do
  begin
    Result := $'{Base}-{N}.wav';
    Inc(N);
  end;
end;

procedure TZXSpectrum48.FinishSave;
var
  Filename: String;
begin
  FSaveRecording := False;
  FSaveArmed := False;

  if FSaveEnabled and (FSaveCount >= 2) then
  begin
    Filename := SaveOutputPath;
    if WriteSaveWAV(Filename) and Assigned(OnTapeSaved) then
      OnTapeSaved(Filename);
  end;

  FSaveCount := 0;
  FSaveName := '';
end;

{ Renders the captured MIC transitions as 8-bit unsigned mono PCM - the same
  shape LoadWAV reads back, so a saved file re-loads. }
function TZXSpectrum48.WriteSaveWAV(const AFilename: String): Boolean;
const
  { Enough tail that the final pulse isn't clipped by the end of the file. }
  TrailingSamples = WavSampleRate div 5;
var
  FS: TFileStream;
  Data: TBytes;
  Base: QWord;
  Total, Idx, Next, I: Integer;
  Level: Boolean;

  function SampleOf(ATState: QWord): Integer;
  begin
    Result := (Int64(ATState - Base) * WavSampleRate) div CPUClockHz;
  end;

  procedure Run(AUpTo: Integer);
  begin
    if AUpTo > Total then AUpTo := Total;
    if AUpTo > Idx then
    begin
      FillByte(Data[Idx], AUpTo - Idx, if Level then 255 else 0);
      Idx := AUpTo;
    end;
  end;

  procedure Tag(const ATag: String);
  begin
    FS.WriteBuffer(ATag[1], 4);
  end;

begin
  Result := False;
  if FSaveCount < 2 then Exit;

  Base := FSaveEdges[0];
  Total := SampleOf(FSaveEdges[FSaveCount - 1]) + TrailingSamples;
  if Total <= 0 then Exit;

  SetLength(Data, Total);
  Level := FSaveStartLevel;
  Idx := 0;

  for I := 0 to FSaveCount - 1 do
  begin
    Run(SampleOf(FSaveEdges[I]));
    Level := not Level;
  end;
  Run(Total);

  FS := autofree TFile.OpenOrCreate(AFilename);
  FS.Size := 0;

  Tag('RIFF');
  FS.WriteDWord(36 + Total);
  Tag('WAVE');

  Tag('fmt ');
  FS.WriteDWord(16);
  FS.WriteWord(1);                { PCM }
  FS.WriteWord(1);                { mono }
  FS.WriteDWord(WavSampleRate);
  FS.WriteDWord(WavSampleRate);   { byte rate = rate * blockAlign }
  FS.WriteWord(1);                { block align }
  FS.WriteWord(8);                { bits per sample }

  Tag('data');
  FS.WriteDWord(Total);
  FS.WriteBuffer(Data[0], Total);

  Result := True;
end;

function TZXSpectrum48.LoadWAV(const AFilename: String): Boolean;
var
  FS: TFileStream;
  ChunkID: array[0..3] of AnsiChar;
  ChunkSize: LongWord;
  AudioFormat, NumChannels, BitsPerSample, BlockAlign: Word;
  SampleRate: LongWord;
  DataStart, DataSize: Int64;
  HaveFmt: Boolean;
  Tag: String;

  function ReadTag: String;
  begin
    if FS.Read(ChunkID[0], 4) <> 4 then Exit('');
    SetString(Result, PAnsiChar(@ChunkID[0]), 4);
  end;

  { Run-length-encodes the thresholded mono signal into FWavEdges. A slow
    EMA tracks the DC bias so off-centre cassette rips still resolve; a
    hysteresis band rejects noise near the crossing. }
  procedure BuildEdges;
  const
    FullScale = 32768;
    Hysteresis = FullScale div 12;
  var
    Raw: TBytes;
    FrameCount, Frame, Ch, Offset, BytesPerSample: Integer;
    Acc, Sample: Integer;
    BiasAcc: Int64;
    Bias, Delta: Integer;
    Level, Prev: Boolean;
    Count: Integer;
  begin
    SetLength(Raw, DataSize);
    FS.Position := DataStart;
    if DataSize > 0 then FS.ReadBuffer(Raw[0], DataSize);

    BytesPerSample := BitsPerSample div 8;
    FrameCount := DataSize div BlockAlign;

    BiasAcc := 0;
    Level := False;
    Prev := False;
    FWavStartLevel := False;
    Count := 0;
    SetLength(FWavEdges, 0);

    for Frame := 0 to FrameCount - 1 do
    begin
      Acc := 0;
      for Ch := 0 to NumChannels - 1 do
      begin
        Offset := Frame * BlockAlign + Ch * BytesPerSample;
        if BitsPerSample = 16 then
          Inc(Acc, SmallInt(Raw[Offset] or (Word(Raw[Offset + 1]) shl 8)))
        else
          Inc(Acc, (Integer(Raw[Offset]) - 128) * 256); { 8-bit unsigned -> centred 16-bit }
      end;
      Sample := Acc div NumChannels;

      BiasAcc := BiasAcc + (Sample - (BiasAcc div 4096));
      Bias := BiasAcc div 4096;
      Delta := Sample - Bias;

      if Delta > Hysteresis then Level := True
      else if Delta < -Hysteresis then Level := False;

      if Level <> Prev then
      begin
        if Count >= Length(FWavEdges) then
          SetLength(FWavEdges, Max(1024, Length(FWavEdges) * 2));
        FWavEdges[Count] := (Int64(Frame) * CPUClockHz) div SampleRate;
        Inc(Count);
        Prev := Level;
      end;
    end;

    SetLength(FWavEdges, Count);
  end;

begin
  Result := False;
  FWavLoaded := False;
  FTapePlaying := False;
  FTapeArmed := False;
  FTapePausedT := 0;
  FWavCursor := 0;
  SetLength(FWavEdges, 0);

  if not TFile.Exists(AFilename) then Exit;

  FS := autofree TFile.OpenRead(AFilename);
  if (ReadTag <> 'RIFF') then Exit;
  FS.ReadDWord; { RIFF chunk size - ignored }
  if (ReadTag <> 'WAVE') then Exit;

  HaveFmt := False;
  DataStart := -1;
  DataSize := 0;
  NumChannels := 0;
  BlockAlign := 0;

  while FS.Position + 8 <= FS.Size do
  begin
    Tag := ReadTag;
    if Length(Tag) < 4 then Break;
    ChunkSize := FS.ReadDWord;

    if Tag = 'fmt ' then
    begin
      AudioFormat := FS.ReadWord;
      NumChannels := FS.ReadWord;
      SampleRate := FS.ReadDWord;
      FS.ReadDWord;            { byte rate }
      BlockAlign := FS.ReadWord;
      BitsPerSample := FS.ReadWord;
      HaveFmt := True;
      if ChunkSize > 16 then FS.Position := FS.Position + (ChunkSize - 16);
    end
    else if Tag = 'data' then
    begin
      DataStart := FS.Position;
      DataSize := ChunkSize;
      if DataStart + DataSize > FS.Size then DataSize := FS.Size - DataStart;
      FS.Position := FS.Position + ChunkSize + (ChunkSize and 1);
    end
    else
      FS.Position := FS.Position + ChunkSize + (ChunkSize and 1);

    if HaveFmt and (DataStart >= 0) then Break;
  end;

  if not HaveFmt or (DataStart < 0) then Exit;
  if AudioFormat <> 1 then Exit;                     { PCM only }
  if (BitsPerSample <> 8) and (BitsPerSample <> 16) then Exit;
  if NumChannels < 1 then Exit;
  if BlockAlign = 0 then BlockAlign := NumChannels * (BitsPerSample div 8);

  BuildEdges;

  Result := Length(FWavEdges) > 0;
  if Result then
  begin
    FWavLoaded := True;
    ROM[LDBytesAddress] := Z80_HOOK;
    ROM[SALDRetAddress] := Z80_HOOK;

    { A WAV replaces any .TAP fast-load tape. }
    FTapeLoaded := False;
    FTapeCursor := 0;
    SetLength(FTapeBlocks, 0);
  end;
end;

end.
